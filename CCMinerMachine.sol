pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";
import "./interfaces/IStake.sol";
import "./interfaces/ILedger.sol";
import "./interfaces/IRelation.sol";
import "./interfaces/ICCLP.sol";


contract CCMinerMachine is Initializable, AdminRoleUpgrade {
    using SafeERC20 for IERC20;


    enum Tier {
        C1,
        C2,
        C3,
        C4,
        C5,
        C6
    }


    struct TierConfig {
        uint256 price;
        uint16 monthlyRateBps;
        uint16 addDays;
        uint16 maxShares;
        bool enabled;
    }


    struct SlotView {
        uint8 slot;
        uint8 round;
        uint16 nextCycleDays;
        bool occupied;
    }

    uint16 internal constant INITIAL_CYCLE_DAYS = 30;
    uint16 internal constant CAP_CYCLE_DAYS = 90;


    IERC20 public paymentToken;

    address public treasury;

    IStake public stake;

    ILedger public ledger;


    mapping(Tier => TierConfig) public tiers;

    mapping(address => mapping(Tier => uint256)) public purchasedCount;


    IRelation public relation;


    ICCLP public lp;


    mapping(address => bool) public isSpender;


    mapping(address => mapping(Tier => mapping(uint256 => uint256))) public slotRounds;

    error ErrorTierDisabled();
    error ErrorNoFreeShare();
    error ErrorPaymentExceedsPrice();
    error ErrorNotBound();
    error ErrorArrayLengthMismatch();
    error ErrorUnauthorized();
    error ErrorInvalidCount();


    event MinerPurchased(
        address indexed buyer,
        Tier indexed tier,
        uint256 price,
        uint16 cycleDays,
        uint256 monthlyYield,
        uint256 cccAtPurchase,
        uint256 totalCashYield,
        uint256 totalCccAtPurchase,
        uint256 useReCash,
        uint256 useCash,
        uint256 useU,
        uint256 purchaseIndex,
        bool hasPerformance,
        bool byAdmin,
        uint8 slot,
        uint8 round
    );
    event SpenderUpdated(address indexed account, bool status);

    modifier onlySpender() {
        if (!isSpender[msg.sender]) revert ErrorUnauthorized();
        _;
    }

    modifier onlyAdminOrSpender() {
        if (!isAdmin(msg.sender) && !isSpender[msg.sender]) revert ErrorUnauthorized();
        _;
    }

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);


        tiers[Tier.C1] = TierConfig(100e18, 2000, 1, 8, true);
        tiers[Tier.C2] = TierConfig(500e18, 2200, 2, 6, true);
        tiers[Tier.C3] = TierConfig(1000e18, 2400, 3, 4, true);

        tiers[Tier.C4] = TierConfig(5000e18, 2600, 4, 2, false);
        tiers[Tier.C5] = TierConfig(10000e18, 2800, 5, 1, false);
        tiers[Tier.C6] = TierConfig(50000e18, 3000, 6, 1, false);
    }

    function setAboutAddress(
        address paymentToken_,
        address stake_,
        address ledger_,
        address treasury_,
        address relation_,
        address lp_
    ) external onlyAdmin {
        paymentToken = IERC20(paymentToken_);
        stake = IStake(stake_);
        ledger = ILedger(ledger_);
        treasury = treasury_;
        relation = IRelation(relation_);
        lp = ICCLP(lp_);
    }


    function setTierEnabled(Tier tier, bool enabled) external onlyAdminOrSpender {
        tiers[tier].enabled = enabled;
    }


    function setSpender(address account, bool status) external onlyAdmin {
        isSpender[account] = status;
        emit SpenderUpdated(account, status);
    }


    function cycleForRound(Tier tier, uint256 round) public view returns (uint16) {
        uint16 add = tiers[tier].addDays;
        uint256 linear = uint256(INITIAL_CYCLE_DAYS) + round * uint256(add);
        if (linear <= CAP_CYCLE_DAYS) {
            return uint16(linear);
        }

        uint256 rCap = uint256(CAP_CYCLE_DAYS - INITIAL_CYCLE_DAYS) / uint256(add);
        uint256 k = round - rCap;

        if (k > 9) {
            k = 9;
        }
        return uint16(uint256(CAP_CYCLE_DAYS) << k);
    }


    function buy(Tier tier, uint256 useReCash, uint256 useCash) external {
        _buyBatch(msg.sender, tier, 1, useReCash, useCash);
    }


    function buyBatch(Tier tier, uint256 count, uint256 useReCash, uint256 useCash) external {
        _buyBatch(msg.sender, tier, count, useReCash, useCash);
    }

    function _buyBatch(address buyer, Tier tier, uint256 count, uint256 useReCash, uint256 useCash) internal {
        if (count == 0) revert ErrorInvalidCount();
        if (relation.Inviter(buyer) == address(0)) revert ErrorNotBound();
        stake.releaseMatured(buyer);

        TierConfig memory config = tiers[tier];
        if (!config.enabled) revert ErrorTierDisabled();

        (uint256 mask, uint256 legacyCount) = stake.slotStateByTier(buyer, uint8(tier));
        if (_popcount(mask) + legacyCount + count > config.maxShares) revert ErrorNoFreeShare();

        uint256 totalPrice = config.price * count;
        if (useReCash + useCash > totalPrice) revert ErrorPaymentExceedsPrice();

        uint256 purchased = purchasedCount[buyer][tier];
        uint256 monthlyYield = (config.price * config.monthlyRateBps) / 10000;

        uint256 cccAtPurchase = address(lp) == address(0) ? 0 : lp.quoteCashToCcc(monthlyYield);

        if (useReCash > 0 || useCash > 0) {
            ledger.spend(buyer, useReCash, useCash);
        }
        uint256 totalUseU = totalPrice - useReCash - useCash;
        if (totalUseU > 0) {

            paymentToken.safeTransferFrom(buyer, address(lp), totalUseU);
            lp.onMinerPurchase(buyer, totalUseU);
        }

        uint256[] memory rounds = _loadRounds(buyer, tier, config.maxShares);
        uint256 remRe = useReCash;
        uint256 remCash = useCash;
        for (uint256 i = 0; i < count; ) {
            (uint8 slot, uint8 round) = _pickSlot(rounds, mask, config.maxShares);
            uint16 cycleDays = cycleForRound(tier, round);
            rounds[slot] = uint256(round) + 1;
            mask |= (uint256(1) << slot);

            unchecked {
                purchased += 1;
            }

            uint256 re = remRe > config.price ? config.price : remRe;
            remRe -= re;
            uint256 roomForCash = config.price - re;
            uint256 cash = remCash > roomForCash ? roomForCash : remCash;
            remCash -= cash;
            uint256 useU = config.price - re - cash;

            stake.openPosition(
                buyer,
                uint8(tier),
                slot + 1,
                config.price,
                cycleDays,
                monthlyYield,
                cccAtPurchase
            );

            emit MinerPurchased(
                buyer,
                tier,
                config.price,
                cycleDays,
                monthlyYield,
                cccAtPurchase,
                stake.totalCashYield(buyer),
                stake.totalCccAtPurchase(buyer),
                re,
                cash,
                useU,
                purchased,
                true,
                false,
                slot,
                round
            );

            unchecked {
                ++i;
            }
        }
        purchasedCount[buyer][tier] = purchased;
        _saveRounds(buyer, tier, rounds);
    }


    function buyByAdmin(
        address[] calldata accounts,
        Tier[] calldata tierList,
        bool[] calldata hasPerformance
    ) external onlySpender {
        uint256 length = accounts.length;
        if (length != tierList.length || length != hasPerformance.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < length; ) {
            _buyByAdmin(accounts[i], tierList[i], hasPerformance[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _buyByAdmin(address account, Tier tier, bool hasPerformance) internal {
        if (relation.Inviter(account) == address(0)) revert ErrorNotBound();
        stake.releaseMatured(account);

        TierConfig memory config = tiers[tier];
        if (!config.enabled) revert ErrorTierDisabled();

        (uint256 mask, uint256 legacyCount) = stake.slotStateByTier(account, uint8(tier));
        if (_popcount(mask) + legacyCount >= config.maxShares) revert ErrorNoFreeShare();

        uint256[] memory rounds = _loadRounds(account, tier, config.maxShares);
        (uint8 slot, uint8 round) = _pickSlot(rounds, mask, config.maxShares);
        uint16 cycleDays = cycleForRound(tier, round);
        rounds[slot] = uint256(round) + 1;

        uint256 monthlyYield = (config.price * config.monthlyRateBps) / 10000;
        uint256 purchaseIndex = purchasedCount[account][tier] + 1;
        uint256 cccAtPurchase = address(lp) == address(0) ? 0 : lp.quoteCashToCcc(monthlyYield);

        purchasedCount[account][tier] = purchaseIndex;
        _saveRounds(account, tier, rounds);
        stake.openPosition(
            account,
            uint8(tier),
            slot + 1,
            config.price,
            cycleDays,
            monthlyYield,
            cccAtPurchase
        );

        emit MinerPurchased(
            account,
            tier,
            config.price,
            cycleDays,
            monthlyYield,
            cccAtPurchase,
            stake.totalCashYield(account),
            stake.totalCccAtPurchase(account),
            hasPerformance ? config.price : 0,
            0,
            0,
            purchaseIndex,
            hasPerformance,
            true,
            slot,
            round
        );
    }


    function _pickSlot(uint256[] memory rounds, uint256 occupiedMask, uint256 maxShares)
        internal
        pure
        returns (uint8 slot, uint8 round)
    {
        bool found;
        for (uint256 i = 0; i < maxShares; ) {
            if (occupiedMask & (uint256(1) << i) == 0) {
                uint8 r = uint8(rounds[i]);
                if (!found || r > round) {
                    found = true;
                    slot = uint8(i);
                    round = r;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _loadRounds(address user, Tier tier, uint256 maxShares)
        internal
        view
        returns (uint256[] memory rounds)
    {
        rounds = new uint256[](maxShares);
        for (uint256 i = 0; i < maxShares; ) {
            rounds[i] = slotRounds[user][tier][i];
            unchecked {
                ++i;
            }
        }
    }

    function _saveRounds(address user, Tier tier, uint256[] memory rounds) internal {
        uint256 len = rounds.length;
        for (uint256 i = 0; i < len; ) {
            if (slotRounds[user][tier][i] != rounds[i]) {
                slotRounds[user][tier][i] = rounds[i];
            }
            unchecked {
                ++i;
            }
        }
    }

    function _popcount(uint256 x) internal pure returns (uint256 count) {
        while (x != 0) {
            unchecked {
                ++count;
            }
            x &= x - 1;
        }
    }


    function getTier(Tier tier) external view returns (TierConfig memory info) {
        return tiers[tier];
    }


    function getTiers() external view returns (TierConfig[] memory list) {
        list = new TierConfig[](6);
        for (uint256 i = 0; i < 6; ) {
            list[i] = tiers[Tier(i)];
            unchecked {
                ++i;
            }
        }
    }


    function getSlots(address user, Tier tier) external view returns (SlotView[] memory list) {
        TierConfig memory config = tiers[tier];
        (uint256 mask, ) = stake.slotStateByTier(user, uint8(tier));
        list = new SlotView[](config.maxShares);
        for (uint256 i = 0; i < config.maxShares; ) {
            uint8 r = uint8(slotRounds[user][tier][i]);
            list[i] = SlotView({
                slot: uint8(i),
                round: r,
                nextCycleDays: cycleForRound(tier, r),
                occupied: (mask & (uint256(1) << i)) != 0
            });
            unchecked {
                ++i;
            }
        }
    }


    function getUserTier(address user, Tier tier)
        external
        view
        returns (
            uint256 purchased,
            uint256 active,
            uint256 matured,
            uint256 currentRound,
            uint16 nextCycleDays,
            uint256 freeShares
        )
    {
        TierConfig memory config = tiers[tier];
        purchased = purchasedCount[user][tier];
        (uint256 mask, uint256 legacyCount) = stake.slotStateByTier(user, uint8(tier));
        active = _popcount(mask) + legacyCount;
        matured = stake.maturedActiveCount(user, uint8(tier));
        freeShares = active >= config.maxShares ? 0 : config.maxShares - active;
        if (freeShares > 0) {
            uint256[] memory rounds = _loadRounds(user, tier, config.maxShares);
            (, uint8 round) = _pickSlot(rounds, mask, config.maxShares);
            currentRound = round;
            nextCycleDays = cycleForRound(tier, round);
        }
    }
}
