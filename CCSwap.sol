pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";
import "./interfaces/ICCSwap.sol";
import "./interfaces/ICCCToken.sol";
import "./interfaces/IPancakeRouter02.sol";

interface IUniswapV2PairView {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract CCSwap is Initializable, AdminRoleUpgrade, ICCSwap {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant PROFIT_BURN_BPS = 500;
    uint256 public constant PROFIT_COBUILDER_BPS = 400;
    uint256 public constant PROFIT_COMMUNITY_BPS = 400;
    uint256 public constant PROFIT_OPS_BPS = 400;
    uint256 public constant PROFIT_NODE_BPS = 300;

    enum QuoteRoute {
        Direct,
        ViaPool,
        ViaWbnb
    }

    IERC20 public ccc;
    IPancakeRouter02 public router;
    address public wbnb;
    address public usdt;

    address public bnbUsdtPool;

    address[] internal pathBnbToCcc;
    address[] internal pathCccToBnb;

    mapping(address => uint256) public userBuyUSDTAmount;
    uint256 public profitTaxBps;
    uint256 public swapFeeBps;

    uint256 public feeEarn;

    address public lpModule;

    bool private _locked;

    address public coBuilderReceiver;
    address public communityReceiver;
    address public opsReceiver;
    address public nodeReceiver;

    mapping(address => uint256) public userBuyBNBAmount;

    mapping(address => uint256) public userBuyCCCAmount;

    mapping(address => uint256) public userSellCCCAmount;

    mapping(address => uint256) public userSellBNBAmount;

    struct Channel {
        bool enabled;
        bool isNative;
        QuoteRoute route;
        address pair;
        address quoteToken;
        address quoteUsdtPool;
        address quoteWbnbPool;
        address[] pathIn;
        address[] pathOut;
    }

    mapping(address => Channel) internal _channels;
    address[] public channelList;

    mapping(address => mapping(address => uint256)) public userBuyQuoteAmount;

    mapping(address => mapping(address => uint256)) public userSellQuoteAmount;

    mapping(address => uint256) public dailySellLimit;

    mapping(address => mapping(uint256 => uint256)) public dailySoldAmount;
    mapping(address => bool) public isSpender;

    bool public isDailyPriceGuardEnabled;

    mapping(address => mapping(uint256 => uint256)) public dailyHighestCccPrice;

    error ErrorZeroAmount();
    error ErrorZeroAddress();
    error ErrorUnauthorized();
    error ErrorMainPairNotSet();
    error ErrorSlippage();
    error ErrorReentrancy();
    error ErrorMsgValueMismatch();
    error ErrorArrayLengthMismatch();
    error ErrorChannelNotFound();
    error ErrorChannelDisabled();
    error ErrorChannelIsNative();
    error ErrorPairNotRegistered();
    error ErrorQuoteTokenMismatch();
    error ErrorInvalidPairPrice(address pair);
    error ErrorDailyPriceDropExceeded(address pair, uint256 price, uint256 highestPrice);

    event Bought(address indexed user, uint256 bnbIn, uint256 cccOut, uint256 usdtCost);

    event Sold(address indexed user, uint256 cccIn, uint256 bnbOut, uint256 burnedFromPair);

    event BoughtVia(address indexed quoteToken, address indexed user, uint256 quoteIn, uint256 cccOut, uint256 usdtCost);

    event SoldVia(address indexed quoteToken, address indexed user, uint256 cccIn, uint256 quoteOut, uint256 burnedFromPair);

    event UserBuyUSDTAdded(address indexed user, uint256 addedAmount, uint256 totalAmount);

    event UserBuyUSDTReduced(address indexed user, uint256 reducedAmount, uint256 totalAmount);

    event ProfitTaxCharged(address indexed user, uint256 profitAmount, uint256 taxAmount);

    event ProfitTaxAllotted(uint256 allotTime, uint256 allotAmount);

    event ProfitTaxBpsUpdated(uint256 bps);

    event DailySoldAccrued(address indexed quoteToken, uint256 indexed day, uint256 amount, uint256 total);

    modifier nonReentrant() {
        if (_locked) revert ErrorReentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlySpender() {
        if (!isSpender[msg.sender]) revert ErrorUnauthorized();
        _;
    }

    function initialize() public initializer {

        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setSpender(address spender, bool isSpender_) external onlyAdmin {
        isSpender[spender] = isSpender_;
    }

    function setAboutAddress(
        address ccc_,
        address router_,
        address wbnb_,
        address usdt_,
        address bnbUsdtPool_
    ) external onlyAdmin {
        if (
            ccc_ == address(0) ||
            router_ == address(0) ||
            wbnb_ == address(0) ||
            usdt_ == address(0) ||
            bnbUsdtPool_ == address(0)
        ) {
            revert ErrorZeroAddress();
        }

        ccc = IERC20(ccc_);
        router = IPancakeRouter02(router_);
        wbnb = wbnb_;
        usdt = usdt_;
        bnbUsdtPool = bnbUsdtPool_;
        profitTaxBps = 2000;
        swapFeeBps = 25;

        pathBnbToCcc = new address[](2);
        pathBnbToCcc[0] = wbnb_;
        pathBnbToCcc[1] = ccc_;

        pathCccToBnb = new address[](2);
        pathCccToBnb[0] = ccc_;
        pathCccToBnb[1] = wbnb_;

        ccc.forceApprove(router_, type(uint256).max);

    }

    receive() external payable {}

    function registerChannel(address quoteToken, address pair) external onlyAdmin {
        _registerChannel(quoteToken, pair);
    }

    function _registerChannel(address quoteToken, address pair) internal {
        if (quoteToken == address(0) || pair == address(0)) revert ErrorZeroAddress();

        ICCCToken token = ICCCToken(address(ccc));
        if (!token.isPair(pair)) revert ErrorPairNotRegistered();
        if (token.pairQuoteToken(pair) != quoteToken) revert ErrorQuoteTokenMismatch();

        Channel storage ch = _channels[quoteToken];
        if (ch.quoteToken == address(0)) {
            channelList.push(quoteToken);
        }

        bool isNative_ = quoteToken == wbnb;
        ch.enabled = true;
        ch.isNative = isNative_;

        ch.route = QuoteRoute.ViaPool;
        ch.pair = pair;
        ch.quoteToken = quoteToken;
        ch.quoteUsdtPool = isNative_ ? bnbUsdtPool : address(0);
        ch.quoteWbnbPool = address(0);

        ch.pathIn = new address[](2);
        ch.pathIn[0] = quoteToken;
        ch.pathIn[1] = address(ccc);

        ch.pathOut = new address[](2);
        ch.pathOut[0] = address(ccc);
        ch.pathOut[1] = quoteToken;

        if (!isNative_) {
            IERC20(quoteToken).forceApprove(address(router), type(uint256).max);
        }

    }

    function registerNativeChannel() external onlyAdmin {
        _registerChannel(wbnb, ICCCToken(address(ccc)).mainPair());
    }

    function setChannelEnabled(address quoteToken, bool enabled) external onlyAdmin {
        Channel storage ch = _channels[quoteToken];
        if (ch.quoteToken == address(0)) revert ErrorChannelNotFound();
        ch.enabled = enabled;
    }

    function setProfitTaxBps(uint256 bps) external onlyAdmin {
        require(bps <= BPS, "profit tax exceeds bps");
        profitTaxBps = bps;
    }

    function setSwapFeeBps(uint256 bps) external onlyAdmin {
        require(bps <= 1000, "swap fee too high");
        swapFeeBps = bps;
    }

    function setDailyPriceGuardEnabled(bool enabled) external onlyAdmin {
        isDailyPriceGuardEnabled = enabled;
    }

    function setDailySellLimits(address[] calldata quoteTokens, uint256[] calldata limits) external onlySpender {
        if (quoteTokens.length != limits.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < quoteTokens.length; i++) {
            if (quoteTokens[i] == address(0)) revert ErrorZeroAddress();
            dailySellLimit[quoteTokens[i]] = limits[i];
        }
    }

    function setLpModule(address account) external onlyAdmin {
        if (account == address(0)) revert ErrorZeroAddress();
        lpModule = account;
    }

    function setFeeReceivers(
        address coBuilder_,
        address community_,
        address ops_,
        address node_
    ) external onlyAdmin {
        if (
            coBuilder_ == address(0) ||
            community_ == address(0) ||
            ops_ == address(0) ||
            node_ == address(0)
        ) {
            revert ErrorZeroAddress();
        }
        coBuilderReceiver = coBuilder_;
        communityReceiver = community_;
        opsReceiver = ops_;
        nodeReceiver = node_;

    }

    function addUserBuyUSDT(address user, uint256 usdtAmount) external onlyAdmin {

        _addUserBuyUSDT(user, usdtAmount);
    }

    function batchAddUserBuyUSDT(address[] calldata users, uint256[] calldata amounts) external onlyAdmin {
        uint256 length = users.length;
        if (length != amounts.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < length; ) {
            _addUserBuyUSDT(users[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    function withdrawFromPair(address to, uint256 amount) external {
        if (msg.sender != lpModule) revert ErrorUnauthorized();
        ICCCToken(address(ccc)).withdrawFromPair(to, amount);
    }

    function withdrawFromPairAt(address pair, address to, uint256 amount) external {
        if (msg.sender != lpModule) revert ErrorUnauthorized();
        ICCCToken(address(ccc)).withdrawFromPairAt(pair, to, amount);
    }

    function buy(uint256 amountIn, uint256 amountOutMin, uint256 deadline) external payable nonReentrant {
        require(false, "not open");
        if (amountIn == 0) revert ErrorZeroAmount();
        if (msg.value != amountIn) revert ErrorMsgValueMismatch();

        Channel storage ch = _channel(wbnb);

        uint256 cccBefore = ccc.balanceOf(address(this));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            amountOutMin,
            ch.pathIn,
            address(this),
            deadline
        );
        uint256 cccOut = ccc.balanceOf(address(this)) - cccBefore;
        if (cccOut == 0) revert ErrorZeroAmount();
        if (cccOut < amountOutMin) revert ErrorSlippage();

        uint256 usdtCost = _bnbToUsdt(amountIn);
        _addUserBuyUSDT(msg.sender, usdtCost);

        ccc.safeTransfer(msg.sender, cccOut);

        userBuyBNBAmount[msg.sender] += amountIn;
        userBuyCCCAmount[msg.sender] += cccOut;
        userBuyQuoteAmount[wbnb][msg.sender] += amountIn;

        emit Bought(msg.sender, amountIn, cccOut, usdtCost);
        emit BoughtVia(wbnb, msg.sender, amountIn, cccOut, usdtCost);
    }

    function sell(uint256 amountIn, uint256 amountOutMin, uint256 deadline) external nonReentrant {
        if (amountIn == 0) revert ErrorZeroAmount();

        Channel storage ch = _channel(wbnb);
        address pair = ch.pair;
        if (pair == address(0)) revert ErrorMainPairNotSet();
        _checkDailyPriceGuard(pair);

        ccc.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 sellAmount = _applyProfitTax(msg.sender, amountIn);
        if (sellAmount == 0) revert ErrorZeroAmount();

        uint256 pairCccBefore = ccc.balanceOf(pair);
        uint256 bnbBefore = address(this).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            sellAmount,
            amountOutMin,
            ch.pathOut,
            address(this),
            deadline
        );

        uint256 landed = _burnLandedCcc(pair, pairCccBefore);

        uint256 bnbOut = address(this).balance - bnbBefore;
        if (bnbOut < amountOutMin) revert ErrorSlippage();

        _accrueDailySell(wbnb, bnbOut);

        (bool ok, ) = msg.sender.call{value: bnbOut}("");
        require(ok, "bnb transfer failed");

        userSellCCCAmount[msg.sender] += amountIn;
        userSellBNBAmount[msg.sender] += bnbOut;
        userSellQuoteAmount[wbnb][msg.sender] += bnbOut;

        emit Sold(msg.sender, amountIn, bnbOut, landed);
        emit SoldVia(wbnb, msg.sender, amountIn, bnbOut, landed);
    }

    function sellForToken(
        address quoteToken,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant {
        if (amountIn == 0) revert ErrorZeroAmount();

        Channel storage ch = _channel(quoteToken);
        if (ch.isNative) revert ErrorChannelIsNative();
        address pair = ch.pair;
        _checkDailyPriceGuard(pair);

        ccc.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 sellAmount = _applyProfitTax(msg.sender, amountIn);
        if (sellAmount == 0) revert ErrorZeroAmount();

        uint256 pairCccBefore = ccc.balanceOf(pair);
        uint256 quoteBefore = IERC20(quoteToken).balanceOf(address(this));

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            sellAmount,
            amountOutMin,
            ch.pathOut,
            address(this),
            deadline
        );

        uint256 landed = _burnLandedCcc(pair, pairCccBefore);

        uint256 quoteOut = IERC20(quoteToken).balanceOf(address(this)) - quoteBefore;
        if (quoteOut < amountOutMin) revert ErrorSlippage();

        _accrueDailySell(quoteToken, quoteOut);

        IERC20(quoteToken).safeTransfer(msg.sender, quoteOut);

        userSellCCCAmount[msg.sender] += amountIn;
        userSellQuoteAmount[quoteToken][msg.sender] += quoteOut;

        emit SoldVia(quoteToken, msg.sender, amountIn, quoteOut, landed);
    }

    function _accrueDailySell(address quoteToken, uint256 amount) internal {
        uint256 today = UTCDateTime.today();
        if (dailySoldAmount[today] + amount > dailySellLimit) revert ErrorDailySellLimitExceeded();
        dailySoldAmount[today] += amount;
    }

    function _checkDailyPriceGuard(address pair) internal {
        uint256 price = _getPairPrice(pair, address(ccc), 1e18);
        if (price == 0) revert ErrorInvalidPairPrice(pair);

        uint256 day = block.timestamp / 1 days;
        uint256 highestPrice = dailyHighestCccPrice[pair][day];
        if (price > highestPrice) {
            dailyHighestCccPrice[pair][day] = price;
            return;
        }

        if (price >= highestPrice * 8_000 / 10_000) {
            return;
        }

        if (!isDailyPriceGuardEnabled) {
            revert ErrorDailyPriceDropExceeded(pair, price, highestPrice);
        }
    }

    function _burnLandedCcc(address pair, uint256 pairCccBefore) internal returns (uint256 landed) {
        uint256 pairCccAfter = ccc.balanceOf(pair);
        landed = pairCccAfter > pairCccBefore ? pairCccAfter - pairCccBefore : 0;
        if (landed > 0 && ICCCToken(address(ccc)).isBurnAllowed()) {
            ICCCToken(address(ccc)).withdrawFromPairAt(pair, DEAD_ADDRESS, landed);
        } else {
            landed = 0;
        }
    }

    function _channel(address quoteToken) internal view returns (Channel storage ch) {
        ch = _channels[quoteToken];
        if (ch.quoteToken == address(0)) revert ErrorChannelNotFound();
        if (!ch.enabled) revert ErrorChannelDisabled();
    }

    function _addUserBuyUSDT(address user, uint256 usdtAmount) internal {
        if (user == address(0)) revert ErrorZeroAddress();
        if (usdtAmount == 0) return;
        userBuyUSDTAmount[user] += usdtAmount;
        emit UserBuyUSDTAdded(user, usdtAmount, userBuyUSDTAmount[user]);
    }

    function _applyProfitTax(address user, uint256 sellAmount) internal returns (uint256) {
        if (sellAmount == 0 || profitTaxBps == 0) {
            return sellAmount;
        }

        uint256 buyUsdtAmount = userBuyUSDTAmount[user];
        uint256 profitCCC;

        if (buyUsdtAmount < 1) {
            profitCCC = sellAmount;
        } else {
            Channel storage priceCh = _channels[wbnb];
            if (priceCh.quoteToken == address(0)) revert ErrorChannelNotFound();

            (uint256 reserveCCC, uint256 reserveBnb) = ICCCToken(address(ccc)).getPairReserves(priceCh.pair);
            uint256 principalBnb = _usdtToBnb(buyUsdtAmount);
            uint256 recoverableBnb = _getAmountOut(sellAmount, reserveCCC, reserveBnb);

            if (recoverableBnb <= principalBnb) {
                _reduceUserBuyUSDT(user, buyUsdtAmount, _bnbToUsdt(recoverableBnb));
                return sellAmount;
            }

            uint256 userCanOutAmount = _getAmountIn(principalBnb, reserveCCC, reserveBnb);
            if (userCanOutAmount >= sellAmount) {
                _reduceUserBuyUSDT(user, buyUsdtAmount, _bnbToUsdt(recoverableBnb));
                return sellAmount;
            }
            profitCCC = sellAmount - userCanOutAmount;
            userBuyUSDTAmount[user] = 0;
            emit UserBuyUSDTReduced(user, buyUsdtAmount, 0);
        }

        uint256 tax = (profitCCC * profitTaxBps) / BPS;
        if (tax == 0) {
            return sellAmount;
        }
        if (tax > sellAmount) {
            tax = sellAmount;
        }

        _allotProfitTax(user, profitCCC, tax);
        return sellAmount - tax;
    }

    function _reduceUserBuyUSDT(address user, uint256 buyUsdtAmount, uint256 sellUsdt) private {
        if (buyUsdtAmount > sellUsdt) {
            userBuyUSDTAmount[user] = buyUsdtAmount - sellUsdt;
            emit UserBuyUSDTReduced(user, sellUsdt, buyUsdtAmount - sellUsdt);
        } else {
            userBuyUSDTAmount[user] = 0;
            emit UserBuyUSDTReduced(user, buyUsdtAmount, 0);
        }
    }

    function _allotProfitTax(address user, uint256 profitCCC, uint256 tax) internal {
        if (tax == 0) return;

        uint256 shareTotal = PROFIT_BURN_BPS +
            PROFIT_COBUILDER_BPS +
            PROFIT_COMMUNITY_BPS +
            PROFIT_OPS_BPS +
            PROFIT_NODE_BPS;

        uint256 cobuilderAmt = (tax * PROFIT_COBUILDER_BPS) / shareTotal;
        uint256 communityAmt = (tax * PROFIT_COMMUNITY_BPS) / shareTotal;
        uint256 opsAmt = (tax * PROFIT_OPS_BPS) / shareTotal;
        uint256 nodeAmt = (tax * PROFIT_NODE_BPS) / shareTotal;
        uint256 burnAmt = tax - cobuilderAmt - communityAmt - opsAmt - nodeAmt;

        feeEarn += tax;

        if (burnAmt > 0) {
            if (ICCCToken(address(ccc)).isBurnAllowed()) {
                ccc.safeTransfer(DEAD_ADDRESS, burnAmt);
            } else {
                opsAmt += burnAmt;
            }
        }
        if (
            coBuilderReceiver == communityReceiver &&
            communityReceiver == nodeReceiver
        ) {
            _safeTransferReceiver(
                coBuilderReceiver,
                cobuilderAmt + communityAmt + nodeAmt
            );
        } else {
            _safeTransferReceiver(coBuilderReceiver, cobuilderAmt);
            _safeTransferReceiver(communityReceiver, communityAmt);
            _safeTransferReceiver(nodeReceiver, nodeAmt);
        }
        _safeTransferReceiver(opsReceiver, opsAmt);

        emit ProfitTaxCharged(user, profitCCC, tax);
        emit ProfitTaxAllotted(block.timestamp, tax);
    }

    function _safeTransferReceiver(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) {
            ccc.safeTransfer(DEAD_ADDRESS, amount);
        } else {
            ccc.safeTransfer(to, amount);
        }
    }

    function _bnbToUsdt(uint256 bnbAmount) internal view returns (uint256) {
        if (bnbAmount == 0) return 0;
        return _getPairPrice(bnbUsdtPool, wbnb, bnbAmount);
    }

    function _usdtToBnb(uint256 usdtAmount) internal view returns (uint256) {
        if (usdtAmount == 0) return 0;
        return _getPairPrice(bnbUsdtPool, usdt, usdtAmount);
    }

    function _getPairPrice(
        address pair,
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256) {
        if (pair == address(0)) return 0;
        address token0 = IUniswapV2PairView(pair).token0();
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2PairView(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return tokenIn == token0
            ? (amountIn * uint256(reserve1)) / uint256(reserve0)
            : (amountIn * uint256(reserve0)) / uint256(reserve1);
    }

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal view returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) {
            return 0;
        }
        uint256 feeBps = swapFeeBps;
        uint256 amountInWithFee = amountIn * (BPS - feeBps);
        return (amountInWithFee * reserveOut) / (reserveIn * BPS + amountInWithFee);
    }

    function _getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal view returns (uint256) {
        if (amountOut == 0 || reserveIn == 0 || reserveOut == 0 || amountOut >= reserveOut) {
            return 0;
        }
        uint256 feeBps = swapFeeBps;
        uint256 numerator = reserveIn * amountOut * BPS;
        uint256 denominator = (reserveOut - amountOut) * (BPS - feeBps);
        return numerator / denominator + 1;
    }

    function rescue(address token, address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert ErrorZeroAddress();
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "bnb rescue failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    function channelCount() external view returns (uint256) {
        return channelList.length;
    }

    function dailySellQuota(address quoteToken)
        external
        view
        returns (uint256 limit, uint256 soldToday, uint256 remainingToday, uint256 day)
    {
        limit = dailySellLimit[quoteToken];
        day = block.timestamp / 1 days;
        soldToday = dailySoldAmount[quoteToken][day];
        if (soldToday >= limit) {
            remainingToday = 0;
        } else {
            remainingToday = limit - soldToday;
        }
    }

    function getChannel(address quoteToken)
        external
        view
        returns (
            bool enabled,
            bool isNative,
            QuoteRoute route,
            address pair,
            address quoteUsdtPool,
            address quoteWbnbPool
        )
    {
        Channel storage ch = _channels[quoteToken];
        return (ch.enabled, ch.isNative, ch.route, ch.pair, ch.quoteUsdtPool, ch.quoteWbnbPool);
    }

    function quoteBuy(uint256 bnbIn) public view returns (uint256 cccOut, uint256 usdtCost) {
        return quoteBuyVia(wbnb, bnbIn);
    }

    function quoteBuyVia(address quoteToken, uint256 amountIn)
        public
        view
        returns (uint256 cccOut, uint256 usdtCost)
    {
        if (amountIn == 0 || quoteToken != wbnb) return (0, 0);
        Channel storage ch = _channels[quoteToken];
        if (ch.quoteToken == address(0)) return (0, 0);

        (uint256 reserveCCC, uint256 reserveQuote) = ICCCToken(address(ccc)).getPairReserves(ch.pair);
        cccOut = _previewCccBuyNet(_getAmountOut(amountIn, reserveQuote, reserveCCC));
        usdtCost = _bnbToUsdt(amountIn);
    }

    function buyEnabled() public view returns (bool) {
        return buyEnabledVia(wbnb);
    }

    function buyEnabledVia(address quoteToken) public view returns (bool) {
        if (quoteToken != wbnb) return false;
        Channel storage ch = _channels[quoteToken];
        if (ch.quoteToken == address(0) || !ch.enabled) return false;

        ICCCToken token = ICCCToken(address(ccc));
        if (ch.pair != token.mainPair()) return true;
        return token.isLpPoolAboveBuyThreshold();
    }

    function _previewCccBuyNet(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;

        ICCCToken token = ICCCToken(address(ccc));
        if (token.isExcluded(address(this))) {
            return amount;
        }

        uint256 feeAmount = (amount * token.buyFeeRatio()) / BPS;
        if (feeAmount > amount) {
            feeAmount = amount;
        }
        return amount - feeAmount;
    }

    function quoteSell(uint256 cccIn) public view returns (uint256 bnbOut) {
        return quoteSellVia(wbnb, cccIn);
    }

    function quoteSellVia(address quoteToken, uint256 cccIn) public view returns (uint256 quoteOut) {
        if (cccIn == 0) return 0;
        Channel storage ch = _channels[quoteToken];
        if (ch.quoteToken == address(0)) return 0;

        uint256 landed = _previewCccSellNet(cccIn, ch.pair);
        if (landed == 0) return 0;

        (uint256 reserveCCC, uint256 reserveQuote) = ICCCToken(address(ccc)).getPairReserves(ch.pair);
        return _getAmountOut(landed, reserveCCC, reserveQuote);
    }

    function previewSell(address user, uint256 amountIn)
        public
        view
        returns (uint256 sellAmount, uint256 bnbOut, uint256 taxAmount)
    {
        return previewSellVia(wbnb, user, amountIn);
    }

    function previewSellVia(address quoteToken, address user, uint256 amountIn)
        public
        view
        returns (uint256 sellAmount, uint256 quoteOut, uint256 taxAmount)
    {
        if (amountIn == 0) return (0, 0, 0);
        Channel storage ch = _channels[quoteToken];
        if (ch.quoteToken == address(0)) return (0, 0, 0);

        uint256 afterProfit;
        (afterProfit, taxAmount) = _previewProfitTax(user, amountIn);
        if (afterProfit == 0) return (0, 0, taxAmount);

        sellAmount = _previewCccSellNet(afterProfit, ch.pair);
        if (sellAmount == 0) return (0, 0, taxAmount);

        (uint256 reserveCCC, uint256 reserveQuote) = ICCCToken(address(ccc)).getPairReserves(ch.pair);
        quoteOut = _getAmountOut(sellAmount, reserveCCC, reserveQuote);
    }

    function _previewCccSellNet(uint256 amount, address pair) internal view returns (uint256) {
        if (amount == 0) return 0;

        ICCCToken token = ICCCToken(address(ccc));
        if (token.isExcluded(address(this))) {
            return amount;
        }

        if (_willChargeAntiDump(token, pair)) {
            uint256 dumpBps = token.ANTI_DUMP_BURN_BPS() + token.ANTI_DUMP_FEE_BPS();
            uint256 dumpTax = (amount * dumpBps) / BPS;
            return amount - dumpTax;
        }

        uint256 feeAmount = (amount * token.sellFeeRatio()) / BPS;
        if (feeAmount > amount) {
            feeAmount = amount;
        }
        return amount - feeAmount;
    }

    function _willChargeAntiDump(ICCCToken token, address pair) internal view returns (bool) {
        (bool active, uint256 activatedAt, uint256 ref) = token.pairAntiDumpState(pair);

        if (active) {

            return block.timestamp < activatedAt + token.ANTI_DUMP_DURATION();
        }

        if (ref == 0) return false;
        uint256 spot = token.getPairPriceInQuote(pair);
        if (spot == 0) return false;

        uint256 floor = (ref * (BPS - token.ANTI_DUMP_DROP_BPS())) / BPS;
        return spot < floor;
    }

    function _previewProfitTax(
        address user,
        uint256 sellAmount
    ) internal view returns (uint256 netSell, uint256 tax) {
        if (sellAmount == 0 || profitTaxBps == 0) {
            return (sellAmount, 0);
        }

        uint256 buyUsdtAmount = userBuyUSDTAmount[user];
        uint256 profitCCC;

        if (buyUsdtAmount < 1) {
            profitCCC = sellAmount;
        } else {
            Channel storage priceCh = _channels[wbnb];
            if (priceCh.quoteToken == address(0)) return (sellAmount, 0);

            (uint256 reserveCCC, uint256 reserveBnb) = ICCCToken(address(ccc)).getPairReserves(priceCh.pair);
            uint256 principalBnb = _usdtToBnb(buyUsdtAmount);
            uint256 recoverableBnb = _getAmountOut(sellAmount, reserveCCC, reserveBnb);

            if (recoverableBnb <= principalBnb) {
                return (sellAmount, 0);
            }

            uint256 userCanOutAmount = _getAmountIn(principalBnb, reserveCCC, reserveBnb);
            if (userCanOutAmount >= sellAmount) {
                return (sellAmount, 0);
            }
            profitCCC = sellAmount - userCanOutAmount;
        }

        tax = (profitCCC * profitTaxBps) / BPS;
        if (tax == 0) {
            return (sellAmount, 0);
        }
        if (tax > sellAmount) {
            tax = sellAmount;
        }
        return (sellAmount - tax, tax);
    }
}
