// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./AdminRoleUpgrade.sol";
import "./libraries/UTCDateTime.sol";
import "./interfaces/ICCLP.sol";
import "./interfaces/ICCSwap.sol";
import "./interfaces/ICCAllowed.sol";
contract CCLedger is Initializable, AdminRoleUpgrade {
    uint256 internal constant BPS = 10_000;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant UUSD = 0x61a10E8556BEd032eA176330e7F17D6a12a10000;
    address internal constant ANOME = 0x6BC3855827fa6EE1229C937A26BB9fCA1a0FfBf0;
    uint256 internal constant DEFAULT_FLASH_DAILY_BNB = 10 ether;
    uint256 internal constant DEFAULT_FLASH_DAILY_UUSD = 10_000 ether;
    uint256 internal constant DEFAULT_FLASH_DAILY_ANOME = 500_000 ether;
    uint256 internal constant DEFAULT_FLASH_USER_BNB = 3 ether;
    uint256 internal constant DEFAULT_FLASH_USER_UUSD = 2_000 ether;
    uint256 internal constant DEFAULT_FLASH_USER_ANOME = 100_000 ether;
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
    mapping(address => uint256) public flashDailyLimit;
    mapping(address => mapping(uint256 => uint256)) public flashDailySold;
    mapping(address => uint256) public flashUserDailyLimit;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public flashUserDailySold;
    error ErrorInsufficientReCash();
    error ErrorInsufficientCash();
    error ErrorLpNotSet();
    error ErrorZeroAmount();
    error ErrorZeroLimit();
    error ErrorLimited();
    error ErrorExceedPerTx();
    error ErrorExceedPerDay();
    error ErrorZeroAddress();
    error ErrorUnauthorized();
    error ErrorDailySellLimitExceeded();
    error ErrorArrayLengthMismatch();
    error ErrorFlashUserLimitExceeded();
    error ErrorFlashDailyLimitExceeded();
    error ErrorCcSwapNotSet();
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
    event CashFlashLog(
        address indexed addr,
        address indexed quoteToken,
        uint256 cashAmount,
        uint256 feeAmount,
        uint256 cccAmount,
        uint256 quoteOut
    );
    event FlashDailySoldAccrued(address indexed quoteToken, uint256 indexed day, uint256 amount, uint256 total);
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
        if (perTx == 0 || perDay == 0) revert ErrorZeroLimit();
        require(perTx <= perDay);
        autoExchangePerTx = perTx;
        autoExchangePerDay = perDay;
    }
    function setFlashDailyLimits(address[] calldata quoteTokens, uint256[] calldata limits) external onlyAdmin {
        if (quoteTokens.length != limits.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < quoteTokens.length; ) {
            if (quoteTokens[i] == address(0)) revert ErrorZeroAddress();
            if (limits[i] == 0) revert ErrorZeroLimit();
            flashDailyLimit[quoteTokens[i]] = limits[i];
            unchecked {
                ++i;
            }
        }
    }
    function setFlashUserDailyLimits(address[] calldata quoteTokens, uint256[] calldata limits)
        external
        onlyAdminOrSpender
    {
        if (quoteTokens.length != limits.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < quoteTokens.length; ) {
            if (quoteTokens[i] == address(0)) revert ErrorZeroAddress();
            if (limits[i] == 0) revert ErrorZeroLimit();
            flashUserDailyLimit[quoteTokens[i]] = limits[i];
            unchecked {
                ++i;
            }
        }
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
    function adjustReCashByAdmin(
        address[] calldata accounts,
        uint256[] calldata amounts,
        bool[] calldata isAdds
    ) external onlyAdminOrSpender {
        uint256 length = accounts.length;
        if (length != amounts.length || length != isAdds.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < length; ) {
            uint256 amount = amounts[i];
            if (amount > 0) {
                address account = accounts[i];
                if (isAdds[i]) {
                    reCashBalance[account] += amount;
                    getReCashEventLog(account, 4, amount, true, msg.sender);
                } else {
                    if (reCashBalance[account] < amount) revert ErrorInsufficientReCash();
                    reCashBalance[account] -= amount;
                    getReCashEventLog(account, 5, amount, false, msg.sender);
                }
            }
            unchecked {
                ++i;
            }
        }
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
    function cashFlashTo(
        address quoteToken,
        uint256 amount,
        uint256 amountOutMin,
        uint256 deadline
    ) external {
        if (quoteToken == address(0)) revert ErrorZeroAddress();
        if (amount == 0) revert ErrorZeroAmount();
        if (autoExchangePerTx > 0 && amount > autoExchangePerTx) revert ErrorExceedPerTx();
        if (autoExchangePerDay > 0 && _usedToday(msg.sender) + amount > autoExchangePerDay) {
            revert ErrorExceedPerDay();
        }
        if (address(allowed) != address(0) && allowed.isLimited(msg.sender)) revert ErrorLimited();
        if (cashBalance[msg.sender] < amount) revert ErrorInsufficientCash();
        if (address(lp) == address(0)) revert ErrorLpNotSet();
        address swap = lp.ccSwap();
        if (swap == address(0)) revert ErrorCcSwapNotSet();
        uint256 feeBps = lp.exchangeFeeBps(msg.sender);
        uint256 feeAmount = (amount * feeBps) / BPS;
        uint256 netCash = amount - feeAmount;
        uint256 cccNet = lp.quoteCashToCcc(netCash);
        if (cccNet == 0) revert ErrorZeroAmount();
        lp.payCccTo(swap, cccNet);
        uint256 quoteOut = ICCSwap(swap).sellForModule(msg.sender, quoteToken, cccNet, amountOutMin, deadline);
        _accrueFlashUserDaily(msg.sender, quoteToken, quoteOut);
        _accrueFlashDaily(quoteToken, quoteOut);
        lp.refillTreasuryFromPools(cccNet);
        cashBalance[msg.sender] -= amount;
        exchangedCashTotal[msg.sender] += amount;
        exchangedCccTotal[msg.sender] += cccNet;
        _accrueAutoExchange(msg.sender, amount);
        getCashEventLog(msg.sender, 7, amount, false, msg.sender);
        emit CashFlashLog(msg.sender, quoteToken, amount, feeAmount, cccNet, quoteOut);
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
    function previewCashFlashTo(address user, address quoteToken, uint256 amount)
        external
        view
        returns (uint256 cccAmount, uint256 feeAmount, uint256 feeBps, uint256 quoteOut, uint256 sellTaxAmount)
    {
        if (amount == 0) revert ErrorZeroAmount();
        if (address(lp) == address(0)) revert ErrorLpNotSet();
        feeBps = lp.exchangeFeeBps(user);
        feeAmount = (amount * feeBps) / BPS;
        uint256 netCash = amount - feeAmount;
        cccAmount = lp.quoteCashToCcc(netCash);
        address swap = lp.ccSwap();
        if (cccAmount == 0 || swap == address(0) || quoteToken == address(0)) {
            return (cccAmount, feeAmount, feeBps, 0, 0);
        }
        (, quoteOut, sellTaxAmount) = ICCSwap(swap).previewSellVia(quoteToken, user, cccAmount);
    }
    function flashDailyQuota(address quoteToken)
        external
        view
        returns (uint256 limit, uint256 soldToday, uint256 remainingToday, uint256 day)
    {
        limit = effectiveFlashDailyLimit(quoteToken);
        day = UTCDateTime.today();
        soldToday = flashDailySold[quoteToken][day];
        if (soldToday >= limit) {
            remainingToday = 0;
        } else {
            remainingToday = limit - soldToday;
        }
    }
    function flashUserDailyQuota(address user, address quoteToken)
        external
        view
        returns (uint256 limit, uint256 soldToday, uint256 remainingToday, uint256 day)
    {
        limit = effectiveFlashUserDailyLimit(quoteToken);
        day = UTCDateTime.today();
        soldToday = flashUserDailySold[user][quoteToken][day];
        if (soldToday >= limit) {
            remainingToday = 0;
        } else {
            remainingToday = limit - soldToday;
        }
    }
    function effectiveFlashDailyLimit(address quoteToken) public view returns (uint256) {
        uint256 configured = flashDailyLimit[quoteToken];
        if (configured > 0) return configured;
        return _defaultFlashDailyLimit(quoteToken);
    }
    function effectiveFlashUserDailyLimit(address quoteToken) public view returns (uint256) {
        uint256 configured = flashUserDailyLimit[quoteToken];
        if (configured > 0) return configured;
        return _defaultFlashUserDailyLimit(quoteToken);
    }
    function flashQuotaDefaults()
        external
        view
        returns (
            uint256 dailyBnb,
            uint256 dailyUusd,
            uint256 dailyAnome,
            uint256 userBnb,
            uint256 userUusd,
            uint256 userAnome
        )
    {
        return (
            effectiveFlashDailyLimit(WBNB),
            effectiveFlashDailyLimit(UUSD),
            effectiveFlashDailyLimit(ANOME),
            effectiveFlashUserDailyLimit(WBNB),
            effectiveFlashUserDailyLimit(UUSD),
            effectiveFlashUserDailyLimit(ANOME)
        );
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
    function _accrueFlashUserDaily(address user, address quoteToken, uint256 amount) internal {
        uint256 limit = effectiveFlashUserDailyLimit(quoteToken);
        uint256 day = UTCDateTime.today();
        uint256 soldToday = flashUserDailySold[user][quoteToken][day];
        if (limit < soldToday + amount) revert ErrorFlashUserLimitExceeded();
        flashUserDailySold[user][quoteToken][day] = soldToday + amount;
    }
    function _accrueFlashDaily(address quoteToken, uint256 amount) internal {
        uint256 day = UTCDateTime.today();
        uint256 soldToday = flashDailySold[quoteToken][day];
        uint256 limit = effectiveFlashDailyLimit(quoteToken);
        if (limit < soldToday + amount) revert ErrorFlashDailyLimitExceeded();
        uint256 total = soldToday + amount;
        flashDailySold[quoteToken][day] = total;
        emit FlashDailySoldAccrued(quoteToken, day, amount, total);
    }
    function _defaultFlashDailyLimit(address quoteToken) internal pure returns (uint256) {
        if (quoteToken == WBNB) return DEFAULT_FLASH_DAILY_BNB;
        if (quoteToken == UUSD) return DEFAULT_FLASH_DAILY_UUSD;
        if (quoteToken == ANOME) return DEFAULT_FLASH_DAILY_ANOME;
        return 0;
    }
    function _defaultFlashUserDailyLimit(address quoteToken) internal pure returns (uint256) {
        if (quoteToken == WBNB) return DEFAULT_FLASH_USER_BNB;
        if (quoteToken == UUSD) return DEFAULT_FLASH_USER_UUSD;
        if (quoteToken == ANOME) return DEFAULT_FLASH_USER_ANOME;
        return 0;
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
