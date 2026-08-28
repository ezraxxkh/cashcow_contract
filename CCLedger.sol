// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./AdminRoleUpgrade.sol";
import "./libraries/UTCDateTime.sol";
import "./interfaces/ICCLP.sol";
import "./interfaces/ICCAllowed.sol";


contract CCLedger is Initializable, AdminRoleUpgrade {

    mapping(address => uint256) public reCashBalance;

    mapping(address => uint256) public cashBalance;


    mapping(address => bool) public isMinter;

    mapping(address => bool) public isSpender;


    ICCLP public lp;

    ICCAllowed public allowed;


    uint256 public autoExchangePerTx;

    uint256 public autoExchangePerDay;

    mapping(address => uint256) public autoExchangedOf;

    mapping(address => uint256) public autoExchangeDayOf;


    mapping(address => uint256) public exchangedCashTotal;

    mapping(address => uint256) public exchangedCccTotal;

    uint256 public dailySellLimit;
    mapping(uint256 => uint256) public dailySoldAmount;

    error ErrorInsufficientReCash();
    error ErrorInsufficientCash();
    error ErrorLpNotSet();
    error ErrorZeroAmount();
    error ErrorLimited();
    error ErrorExceedPerTx();
    error ErrorExceedPerDay();
    error ErrorZeroAddress();
    error ErrorUnauthorized();
    error ErrorDailySellLimitExceeded();

    event ReCashAmountLog(
        address indexed addr,
        uint256 status,
        uint256 amount,
        bool isAdd,
        address indexed from
    );

    event CashAmountLog(
        address indexed addr,
        uint256 status,
        uint256 amount,
        bool isAdd,
        address indexed from
    );


    event CashToCCCLog(
        address indexed addr,
        uint256 cashAmount,
        uint256 feeAmount,
        uint256 cccAmount
    );

    modifier onlyAdminOrSpender() {
        if (!isAdmin(msg.sender) && !isSpender[msg.sender]) revert ErrorUnauthorized();
        _;
    }

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setAboutAddress(address lp_, address allowed_) external onlyAdmin {
        lp = ICCLP(lp_);
        allowed = ICCAllowed(allowed_);
    }

    function setDailySellLimit(uint256 limit) external onlyAdminOrSpender {
        dailySellLimit = limit;
    }


    function setSpender(address account, bool status) external onlyAdmin {
        isSpender[account] = status;
    }


    function setAutoExchangeLimit(uint256 perTx, uint256 perDay) external onlyAdminOrSpender {
        require(perTx == 0 || perDay == 0 || perTx <= perDay);
        autoExchangePerTx = perTx;
        autoExchangePerDay = perDay;
    }


    function stake(address user, uint256 reCashAmount, uint256 cashAmount) external onlyAdmin {
        if (reCashAmount > 0) {
            reCashBalance[user] += reCashAmount;
            getReCashEventLog(user, 3, reCashAmount, true, msg.sender);
        }
        if (cashAmount > 0) {
            cashBalance[user] += cashAmount;
            getCashEventLog(user, 2, cashAmount, true, msg.sender);
        }
    }


    function mint(address user, uint256 reCashAmount, uint256 cashAmount) external onlyAdmin {
        if (reCashAmount > 0) {
            reCashBalance[user] += reCashAmount;
            getReCashEventLog(user, 2, reCashAmount, true, msg.sender);
        }
        if (cashAmount > 0) {
            cashBalance[user] += cashAmount;
            getCashEventLog(user, 2, cashAmount, true, msg.sender);
        }
    }

    function addCash(address user, uint256 cashAmount, uint256 status, address from) external onlyAdmin {
        cashBalance[user] += cashAmount;
        getCashEventLog(user, status, cashAmount, true, from);
    }


    function spend(address user, uint256 reCashAmount, uint256 cashAmount) external onlyAdmin {
        if (reCashAmount > 0) {
            if (reCashBalance[user] < reCashAmount) revert ErrorInsufficientReCash();
            reCashBalance[user] -= reCashAmount;
            getReCashEventLog(user, 1, reCashAmount, false, msg.sender);
        }
        if (cashAmount > 0) {
            if (cashBalance[user] < cashAmount) revert ErrorInsufficientCash();
            cashBalance[user] -= cashAmount;
            getCashEventLog(user, 1, cashAmount, false, msg.sender);
        }
    }


    function cashToCCC(uint256 amount) external {
        if (autoExchangePerTx > 0 && amount > autoExchangePerTx) revert ErrorExceedPerTx();
        if (autoExchangePerDay > 0 && _usedToday(msg.sender) + amount > autoExchangePerDay) {
            revert ErrorExceedPerDay();
        }
        _cashToCCC(msg.sender, amount);
        _accrueAutoExchange(msg.sender, amount);
    }


    function cashToCCCByAdmin(address user, uint256 amount) external onlyAdminOrSpender {
        if (user == address(0)) revert ErrorZeroAddress();
        _cashToCCC(user, amount);
        _accrueAutoExchange(user, amount);
    }


    function exchangeFeeBps(address user) external view returns (uint256) {
        return lp.exchangeFeeBps(user);
    }


    function exchangeFeeRate(address user) external view returns (uint256 feeBps, uint8 tier) {
        return lp.exchangeFeeRate(user);
    }


    function previewCashToCCC(address user, uint256 amount)
        external
        view
        returns (uint256 cccAmount, uint256 feeAmount, uint256 feeBps)
    {
        return lp.previewCashToCCC(user, amount);
    }


    function quoteCashToCcc(uint256 cashAmount) external view returns (uint256) {
        return lp.quoteCashToCcc(cashAmount);
    }


    function autoExchangeQuota(address user)
        external
        view
        returns (uint256 perTx, uint256 perDay, uint256 usedToday, uint256 remainingToday)
    {
        perTx = autoExchangePerTx;
        perDay = autoExchangePerDay;
        usedToday = _usedToday(user);
        if (perDay == 0) {
            remainingToday = type(uint256).max;
        } else if (usedToday >= perDay) {
            remainingToday = 0;
        } else {
            remainingToday = perDay - usedToday;
        }
    }


    function balanceOf(address user) external view returns (uint256 reCash, uint256 cash) {
        return (reCashBalance[user], cashBalance[user]);
    }


    function balanceOfBatch(address[] calldata users)
        external
        view
        returns (uint256[] memory reCash, uint256[] memory cash, uint256[] memory ccc)
    {
        uint256 length = users.length;
        reCash = new uint256[](length);
        cash = new uint256[](length);
        ccc = new uint256[](length);
        IERC20 cccToken = IERC20(lp.ccc());
        for (uint256 i = 0; i < length; ) {
            address user = users[i];
            reCash[i] = reCashBalance[user];
            cash[i] = cashBalance[user];
            ccc[i] = cccToken.balanceOf(user);
            unchecked {
                ++i;
            }
        }
    }

    function _cashToCCC(address user, uint256 amount) internal {

        if (amount == 0) revert ErrorZeroAmount();
        if (address(allowed) != address(0) && allowed.isLimited(user)) revert ErrorLimited();
        if (cashBalance[user] < amount) revert ErrorInsufficientCash();
        if (address(lp) == address(0)) revert ErrorLpNotSet();


        (uint256 cccNet, uint256 feeAmount) = lp.exchange(user, amount);
        cashBalance[user] -= amount;

        exchangedCashTotal[user] += amount;
        exchangedCccTotal[user] += cccNet;
        _accrueDailySell(cccNet);
        getCashEventLog(user, 3, amount, false, msg.sender);
        emit CashToCCCLog(user, amount, feeAmount, cccNet);
    }

    function _accrueDailySell(uint256 amount) internal {
        uint256 today = UTCDateTime.today();
        if (dailySoldAmount[today] + amount > dailySellLimit) revert ErrorDailySellLimitExceeded();
        dailySoldAmount[today] += amount;
    }


    function _accrueAutoExchange(address user, uint256 amount) internal {
        uint256 today = UTCDateTime.today();
        if (autoExchangeDayOf[user] != today) {
            autoExchangeDayOf[user] = today;
            autoExchangedOf[user] = amount;
        } else {
            autoExchangedOf[user] += amount;
        }
    }

    function _usedToday(address user) internal view returns (uint256) {
        if (autoExchangeDayOf[user] != UTCDateTime.today()) return 0;
        return autoExchangedOf[user];
    }


    function getReCashEventLog(address addr, uint256 status, uint256 amount, bool isAdd, address from) internal {

        emit ReCashAmountLog(addr, status, amount, isAdd, from);
    }


    function getCashEventLog(address addr, uint256 status, uint256 amount, bool isAdd, address from) internal {

        emit CashAmountLog(addr, status, amount, isAdd, from);
    }
}
