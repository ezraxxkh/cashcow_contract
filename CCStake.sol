pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";
import "./libraries/UTCDateTime.sol";
import "./interfaces/ILedger.sol";


contract CCStake is Initializable, AdminRoleUpgrade {
    uint256 internal constant SECONDS_PER_DAY = 86400;

    struct Position {
        uint8 tier;
        uint256 principal;
        uint16 cycleDays;
        uint256 monthlyYield;
        uint256 startDay;
        uint256 lastClaimDay;
        uint16 claimedDays;
        bool active;
        uint256 cccAtPurchase;
        uint8 slot;
    }


    address public machine;

    ILedger public ledger;


    mapping(address => uint256) public nextPositionId;

    mapping(address => mapping(uint256 => Position)) public positionById;

    mapping(address => uint256[]) public activeIds;

    mapping(address => mapping(uint256 => uint256)) public activeIndex;


    mapping(address => uint256) public claimTime;


    mapping(address => uint256) public totalCashYield;

    mapping(address => uint256) public totalCccAtPurchase;

    error ErrorOnlyMachine();
    error ErrorNothingToClaim();
    error ErrorNotMatured();
    error ErrorAlreadySettled();
    error ErrorAlreadyClaimedToday();


    event PositionOpened(
        address indexed user,
        uint256 indexed posId,
        uint8 tier,
        uint256 principal,
        uint16 cycleDays,
        uint256 monthlyYield,
        uint256 startDay,
        uint8 slot
    );


    event DailySettlement(
        address indexed user,
        uint256 indexed day,
        uint256 reCashAmount,
        uint256 cashAmount,
        uint256 expiredCount,
        uint256 activePrincipalSum
    );

    modifier onlyMachine() {
        if (msg.sender != machine) revert ErrorOnlyMachine();
        _;
    }

    function initialize() public initializer {

        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setAboutAddress(address machine_, address ledger_) external onlyAdmin {
        machine = machine_;
        ledger = ILedger(ledger_);
    }


    function openPosition(
        address user,
        uint8 tier,
        uint256 principal,
        uint16 cycleDays,
        uint256 monthlyYield,
        uint256 cccAtPurchase
    ) external onlyMachine returns (uint256 posId) {
        return _openPosition(user, tier, 0, principal, cycleDays, monthlyYield, cccAtPurchase);
    }


    function openPosition(
        address user,
        uint8 tier,
        uint8 slot,
        uint256 principal,
        uint16 cycleDays,
        uint256 monthlyYield,
        uint256 cccAtPurchase
    ) external onlyMachine returns (uint256 posId) {
        return _openPosition(user, tier, slot, principal, cycleDays, monthlyYield, cccAtPurchase);
    }

    function _openPosition(
        address user,
        uint8 tier,
        uint8 slot,
        uint256 principal,
        uint16 cycleDays,
        uint256 monthlyYield,
        uint256 cccAtPurchase
    ) internal returns (uint256 id) {
        uint256 startDay = UTCDateTime.today();
        id = nextPositionId[user];

        positionById[user][id] = Position({
            tier: tier,
            principal: principal,
            cycleDays: cycleDays,
            monthlyYield: monthlyYield,
            startDay: startDay,
            lastClaimDay: startDay,
            claimedDays: 0,
            active: true,
            cccAtPurchase: cccAtPurchase,
            slot: slot
        });

        activeIds[user].push(id);
        activeIndex[user][id] = activeIds[user].length;
        nextPositionId[user] = id + 1;

        totalCashYield[user] += monthlyYield;
        totalCccAtPurchase[user] += cccAtPurchase;

        emit PositionOpened(user, id, tier, principal, cycleDays, monthlyYield, startDay, slot);
    }


    function claim() external {
        address user = msg.sender;
        uint256 today = UTCDateTime.today();


        if (claimTime[user] == today) revert ErrorAlreadyClaimedToday();

        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;

        uint256 totalReCash;
        uint256 totalCash;

        uint256[] memory expired = new uint256[](len);
        uint256 expiredCount;

        for (uint256 i = 0; i < len; ) {
            uint256 id = ids[i];
            Position storage pos = positionById[user][id];
            if (block.timestamp >= _maturityOf(pos)) {

                if (pos.active) {
                    pos.active = false;
                    expired[expiredCount] = id;
                    unchecked {
                        ++expiredCount;
                    }
                }
            } else if (today > pos.lastClaimDay && pos.claimedDays < pos.cycleDays) {

                totalReCash += pos.principal / pos.cycleDays;
                totalCash += pos.monthlyYield / pos.cycleDays;
                pos.claimedDays += 1;
                pos.lastClaimDay = today;


                if (pos.claimedDays >= pos.cycleDays || today >= _lastClaimableDay(pos)) {
                    pos.active = false;
                    expired[expiredCount] = id;
                    unchecked {
                        ++expiredCount;
                    }
                }
            } else if (pos.active && pos.lastClaimDay >= _lastClaimableDay(pos)) {

                pos.active = false;
                expired[expiredCount] = id;
                unchecked {
                    ++expiredCount;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (totalReCash == 0 && totalCash == 0 && expiredCount == 0) revert ErrorNothingToClaim();

        claimTime[user] = today;


        if (totalReCash > 0 || totalCash > 0) {
            ledger.stake(user, totalReCash, totalCash);
        }


        for (uint256 j = 0; j < expiredCount; ) {
            uint256 id = expired[j];
            _removeActive(user, id);
            unchecked {
                ++j;
            }
        }

        emit DailySettlement(
            user,
            today,
            totalReCash,
            totalCash,
            expiredCount,
            _activePrincipalSum(user)
        );
    }


    function settleMatured(address user, uint256 posId) external {
        Position storage pos = positionById[user][posId];
        if (!pos.active) revert ErrorAlreadySettled();
        if (!_shouldRelease(pos)) revert ErrorNotMatured();

        pos.active = false;
        _removeActive(user, posId);
    }


    function releaseMatured(address user) public {
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;

        uint256[] memory matured = new uint256[](len);
        uint256 count;
        for (uint256 i = 0; i < len; ) {
            uint256 id = ids[i];
            if (_shouldRelease(positionById[user][id])) {
                matured[count] = id;
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
        for (uint256 j = 0; j < count; ) {
            uint256 id = matured[j];
            positionById[user][id].active = false;
            _removeActive(user, id);
            unchecked {
                ++j;
            }
        }
    }


    function activePrincipalSum(address user) external view returns (uint256) {
        return _activePrincipalSum(user);
    }


    function _activePrincipalSum(address user) internal view returns (uint256 sum) {
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            Position storage pos = positionById[user][ids[i]];
            if (_occupiesShare(pos)) {
                sum += pos.principal;
            }
            unchecked {
                ++i;
            }
        }
    }


    function activeCountByTier(address user, uint8 tier) external view returns (uint256 count) {
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            Position storage pos = positionById[user][ids[i]];
            if (pos.tier == tier && _occupiesShare(pos)) {
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
    }


    function slotStateByTier(address user, uint8 tier)
        external
        view
        returns (uint256 occupiedMask, uint256 legacyCount)
    {
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            Position storage pos = positionById[user][ids[i]];
            if (pos.tier == tier && _occupiesShare(pos)) {
                if (pos.slot == 0) {
                    unchecked {
                        ++legacyCount;
                    }
                } else {
                    occupiedMask |= (uint256(1) << (pos.slot - 1));
                }
            }
            unchecked {
                ++i;
            }
        }
    }


    function maturedActiveCount(address user, uint8 tier) external view returns (uint256 count) {
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            Position storage pos = positionById[user][ids[i]];
            if (pos.tier == tier && _shouldRelease(pos)) {
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
    }


    function _lastClaimableDay(Position storage pos) internal view returns (uint256) {
        return pos.startDay + uint256(pos.cycleDays) * SECONDS_PER_DAY;
    }


    function _maturityOf(Position storage pos) internal view returns (uint256) {
        return pos.startDay + (uint256(pos.cycleDays) + 1) * SECONDS_PER_DAY;
    }


    function _shouldRelease(Position storage pos) internal view returns (bool) {
        return block.timestamp >= _maturityOf(pos) || pos.lastClaimDay >= _lastClaimableDay(pos);
    }


    function _occupiesShare(Position storage pos) internal view returns (bool) {
        return block.timestamp < _maturityOf(pos) && pos.lastClaimDay < _lastClaimableDay(pos);
    }


    function _removeActive(address user, uint256 id) internal {
        uint256 idxPlus = activeIndex[user][id];
        if (idxPlus == 0) return;
        uint256 idx = idxPlus - 1;
        uint256[] storage ids = activeIds[user];
        uint256 lastIdx = ids.length - 1;
        if (idx != lastIdx) {
            uint256 lastId = ids[lastIdx];
            ids[idx] = lastId;
            activeIndex[user][lastId] = idx + 1;
        }
        ids.pop();
        activeIndex[user][id] = 0;
    }


    function activeLength(address user) external view returns (uint256) {
        return activeIds[user].length;
    }


    function getActivePositions(address user) external view returns (Position[] memory list) {
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;
        list = new Position[](len);
        for (uint256 i = 0; i < len; ) {
            list[i] = positionById[user][ids[i]];
            unchecked {
                ++i;
            }
        }
    }


    function pendingClaim(address user)
        external
        view
        returns (
            uint256 reCashAmount,
            uint256 cashAmount,
            bool claimable,
            uint256 pendingReCashAmount,
            uint256 pendingCashAmount
        )
    {
        uint256 today = UTCDateTime.today();
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            Position storage pos = positionById[user][ids[i]];
            if (
                block.timestamp < _maturityOf(pos) &&
                today > pos.lastClaimDay &&
                pos.claimedDays < pos.cycleDays
            ) {
                reCashAmount += pos.principal / pos.cycleDays;
                cashAmount += pos.monthlyYield / pos.cycleDays;
            }


            if (block.timestamp < _maturityOf(pos) && pos.claimedDays < pos.cycleDays) {
                uint256 cycleDays = pos.cycleDays;
                uint256 lastClaimableDay = _lastClaimableDay(pos);

                uint256 firstClaimDay = today > pos.lastClaimDay
                    ? today
                    : today + SECONDS_PER_DAY;

                if (firstClaimDay <= lastClaimableDay) {
                    uint256 remainingByTime =
                        (lastClaimableDay - firstClaimDay) / SECONDS_PER_DAY +
                        1;
                    uint256 remainingByCount =
                        cycleDays - uint256(pos.claimedDays);
                    uint256 remainingDays = remainingByTime < remainingByCount
                        ? remainingByTime
                        : remainingByCount;

                    uint256 dailyReCash = pos.principal / cycleDays;
                    uint256 dailyCash = pos.monthlyYield / cycleDays;
                    pendingReCashAmount += dailyReCash * remainingDays;
                    pendingCashAmount += dailyCash * remainingDays;
                }
            }
            unchecked {
                ++i;
            }
        }

        claimable = (claimTime[user] != today) && (reCashAmount > 0 || cashAmount > 0);
    }


    function pendingClaimTomorrow(address user)
        external
        view
        returns (uint256 reCashAmount, uint256 cashAmount)
    {
        uint256 today = UTCDateTime.today();
        uint256 tomorrow = today + SECONDS_PER_DAY;
        uint256[] storage ids = activeIds[user];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            Position storage pos = positionById[user][ids[i]];
            uint256 claimedDays = pos.claimedDays;
            uint256 lastClaimDay = pos.lastClaimDay;


            if (
                block.timestamp < _maturityOf(pos) &&
                today > lastClaimDay &&
                claimedDays < pos.cycleDays
            ) {
                unchecked {
                    ++claimedDays;
                }
                lastClaimDay = today;
            }

            if (
                tomorrow < _maturityOf(pos) &&
                tomorrow > lastClaimDay &&
                claimedDays < pos.cycleDays
            ) {
                reCashAmount += pos.principal / pos.cycleDays;
                cashAmount += pos.monthlyYield / pos.cycleDays;
            }
            unchecked {
                ++i;
            }
        }
    }
}
