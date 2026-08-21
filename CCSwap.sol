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


contract CCSwap is Initializable, AdminRoleUpgrade, ICCSwap {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE_ALLOT_THRESHOLD = 1000e18;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;


    uint256 public constant PROFIT_BURN_BPS = 500;
    uint256 public constant PROFIT_COBUILDER_BPS = 400;
    uint256 public constant PROFIT_COMMUNITY_BPS = 400;
    uint256 public constant PROFIT_OPS_BPS = 400;
    uint256 public constant PROFIT_NODE_BPS = 300;

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

    error ErrorZeroAmount();
    error ErrorZeroAddress();
    error ErrorUnauthorized();
    error ErrorMainPairNotSet();
    error ErrorSlippage();
    error ErrorReentrancy();
    error ErrorMsgValueMismatch();


    event Bought(address indexed user, uint256 bnbIn, uint256 cccOut, uint256 usdtCost);

    event Sold(address indexed user, uint256 cccIn, uint256 bnbOut, uint256 burnedFromPair);

    event UserBuyUSDTAdded(address indexed user, uint256 addedAmount, uint256 totalAmount);


    event UserBuyUSDTReduced(address indexed user, uint256 reducedAmount, uint256 totalAmount);

    event ProfitTaxCharged(address indexed user, uint256 profitAmount, uint256 taxAmount);

    event ProfitTaxAllotted(uint256 allotTime, uint256 allotAmount);

    event ProfitTaxBpsUpdated(uint256 bps);

    event SwapFeeBpsUpdated(uint256 bps);

    event LpModuleUpdated(address indexed account);


    modifier nonReentrant() {
        if (_locked) revert ErrorReentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    function initialize() public initializer {
        _addAdmin(msg.sender);
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

    function setProfitTaxBps(uint256 bps) external onlyAdmin {
        require(bps <= BPS, "profit tax exceeds bps");
        profitTaxBps = bps;
        emit ProfitTaxBpsUpdated(bps);
    }

    function setSwapFeeBps(uint256 bps) external onlyAdmin {
        require(bps <= 1000, "swap fee too high");
        swapFeeBps = bps;
        emit SwapFeeBpsUpdated(bps);
    }

    function setLpModule(address account) external onlyAdmin {
        if (account == address(0)) revert ErrorZeroAddress();
        lpModule = account;
        emit LpModuleUpdated(account);
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


    function addUserBuyUSDT(address user, uint256 usdtAmount) external {
        if (msg.sender != lpModule) revert ErrorUnauthorized();
        _addUserBuyUSDT(user, usdtAmount);
    }


    function withdrawFromPair(address to, uint256 amount) external {
        if (msg.sender != lpModule) revert ErrorUnauthorized();
        ICCCToken(address(ccc)).withdrawFromPair(to, amount);
    }


    function buy(uint256 amountIn, uint256 amountOutMin, uint256 deadline) external payable nonReentrant {
        if (amountIn == 0) revert ErrorZeroAmount();
        if (msg.value != amountIn) revert ErrorMsgValueMismatch();

        uint256 cccBefore = ccc.balanceOf(address(this));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(
            amountOutMin,
            pathBnbToCcc,
            address(this),
            deadline
        );
        uint256 cccOut = ccc.balanceOf(address(this)) - cccBefore;
        if (cccOut == 0) revert ErrorZeroAmount();
        if (cccOut < amountOutMin) revert ErrorSlippage();

        uint256 usdtCost = _wbnbToUsdt(amountIn);
        _addUserBuyUSDT(msg.sender, usdtCost);

        ccc.safeTransfer(msg.sender, cccOut);
        emit Bought(msg.sender, amountIn, cccOut, usdtCost);
    }


    function sell(uint256 amountIn, uint256 amountOutMin, uint256 deadline) external nonReentrant {
        if (amountIn == 0) revert ErrorZeroAmount();

        address pair = ICCCToken(address(ccc)).mainPair();
        if (pair == address(0)) revert ErrorMainPairNotSet();

        ccc.safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 sellAmount = _applyProfitTax(msg.sender, amountIn);
        if (sellAmount == 0) revert ErrorZeroAmount();

        uint256 pairCccBefore = ccc.balanceOf(pair);
        uint256 bnbBefore = address(this).balance;

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            sellAmount,
            amountOutMin,
            pathCccToBnb,
            address(this),
            deadline
        );

        uint256 pairCccAfter = ccc.balanceOf(pair);
        uint256 landed = pairCccAfter > pairCccBefore ? pairCccAfter - pairCccBefore : 0;
        if (landed > 0) {
            ICCCToken(address(ccc)).withdrawFromPair(DEAD_ADDRESS, landed);
        }

        uint256 bnbOut = address(this).balance - bnbBefore;
        if (bnbOut < amountOutMin) revert ErrorSlippage();

        (bool ok, ) = msg.sender.call{value: bnbOut}("");
        require(ok, "bnb transfer failed");

        emit Sold(msg.sender, amountIn, bnbOut, landed);
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
            (uint256 reserveCCC, uint256 reserveWbnb) = _reserves();
            uint256 principalWbnb = _usdtToWbnb(buyUsdtAmount);
            uint256 recoverableWbnb = _getAmountOut(sellAmount, reserveCCC, reserveWbnb);


            if (recoverableWbnb <= principalWbnb) {
                _reduceUserBuyUSDT(user, buyUsdtAmount, recoverableWbnb);
                return sellAmount;
            }


            uint256 userCanOutAmount = _getAmountIn(principalWbnb, reserveCCC, reserveWbnb);
            if (userCanOutAmount >= sellAmount) {
                _reduceUserBuyUSDT(user, buyUsdtAmount, recoverableWbnb);
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


        feeEarn += tax;
        emit ProfitTaxCharged(user, profitCCC, tax);
        _allotProfitTax();
        return sellAmount - tax;
    }


    function _reduceUserBuyUSDT(address user, uint256 buyUsdtAmount, uint256 recoverableWbnb) private {
        uint256 sellUsdt = _wbnbToUsdt(recoverableWbnb);
        if (buyUsdtAmount > sellUsdt) {
            userBuyUSDTAmount[user] = buyUsdtAmount - sellUsdt;
            emit UserBuyUSDTReduced(user, sellUsdt, buyUsdtAmount - sellUsdt);
        } else {
            userBuyUSDTAmount[user] = 0;
            emit UserBuyUSDTReduced(user, buyUsdtAmount, 0);
        }
    }


    function _allotProfitTax() internal {
        uint256 feeEarn_ = feeEarn;
        if (feeEarn_ < FEE_ALLOT_THRESHOLD || profitTaxBps == 0) {
            return;
        }

        uint256 cobuilderAmt = (feeEarn_ * PROFIT_COBUILDER_BPS) / profitTaxBps;
        uint256 communityAmt = (feeEarn_ * PROFIT_COMMUNITY_BPS) / profitTaxBps;
        uint256 opsAmt = (feeEarn_ * PROFIT_OPS_BPS) / profitTaxBps;
        uint256 nodeAmt = (feeEarn_ * PROFIT_NODE_BPS) / profitTaxBps;
        uint256 burnAmt = feeEarn_ - cobuilderAmt - communityAmt - opsAmt - nodeAmt;
        feeEarn = 0;

        if (burnAmt > 0) ccc.safeTransfer(DEAD_ADDRESS, burnAmt);
        _safeTransferReceiver(coBuilderReceiver, cobuilderAmt);
        _safeTransferReceiver(communityReceiver, communityAmt);
        _safeTransferReceiver(opsReceiver, opsAmt);
        _safeTransferReceiver(nodeReceiver, nodeAmt);

        emit ProfitTaxAllotted(block.timestamp, feeEarn_);
    }

    function _safeTransferReceiver(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) {
            ccc.safeTransfer(DEAD_ADDRESS, amount);
        } else {
            ccc.safeTransfer(to, amount);
        }
    }

    function _reserves() internal view returns (uint256 reserveCCC, uint256 reserveWbnb) {
        address pair = ICCCToken(address(ccc)).mainPair();
        if (pair == address(0)) {
            return (0, 0);
        }
        (uint112 r0, uint112 r1, ) = IUniswapV2PairView(pair).getReserves();
        if (ICCCToken(address(ccc)).cccIsToken0()) {
            reserveCCC = uint256(r0);
            reserveWbnb = uint256(r1);
        } else {
            reserveCCC = uint256(r1);
            reserveWbnb = uint256(r0);
        }
    }

    function _usdtToWbnb(uint256 usdtAmount) internal view returns (uint256) {
        if (usdtAmount == 0) return 0;
        return _getPairPrice(bnbUsdtPool, usdt, usdtAmount);
    }

    function _wbnbToUsdt(uint256 wbnbAmount) internal view returns (uint256) {
        if (wbnbAmount == 0) return 0;
        return _getPairPrice(bnbUsdtPool, wbnb, wbnbAmount);
    }

    function _getPairPrice(
        address pair,
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256) {
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


    function quoteBuy(uint256 bnbIn) public view returns (uint256 cccOut, uint256 usdtCost) {
        if (bnbIn == 0) return (0, 0);
        (uint256 reserveCCC, uint256 reserveWbnb) = _reserves();
        cccOut = _getAmountOut(bnbIn, reserveWbnb, reserveCCC);
        usdtCost = _wbnbToUsdt(bnbIn);
    }


    function quoteSell(uint256 cccIn) public view returns (uint256 bnbOut) {
        if (cccIn == 0) return 0;
        uint256 landed = _previewCccSellNet(cccIn);
        if (landed == 0) return 0;
        (uint256 reserveCCC, uint256 reserveWbnb) = _reserves();
        return _getAmountOut(landed, reserveCCC, reserveWbnb);
    }


    function previewSell(address user, uint256 amountIn)
        public
        view
        returns (uint256 sellAmount, uint256 bnbOut, uint256 taxAmount)
    {
        if (amountIn == 0) return (0, 0, 0);
        uint256 afterProfit;
        (afterProfit, taxAmount) = _previewProfitTax(user, amountIn);
        if (afterProfit == 0) return (0, 0, taxAmount);

        sellAmount = _previewCccSellNet(afterProfit);
        if (sellAmount == 0) return (0, 0, taxAmount);

        (uint256 reserveCCC, uint256 reserveWbnb) = _reserves();
        bnbOut = _getAmountOut(sellAmount, reserveCCC, reserveWbnb);
    }


    function _previewCccSellNet(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;

        ICCCToken token = ICCCToken(address(ccc));
        if (token.isExcluded(address(this))) {
            return amount;
        }

        if (_willChargeAntiDump(token)) {
            uint256 dumpBps = token.ANTI_DUMP_BURN_BPS() + token.ANTI_DUMP_FEE_BPS();
            uint256 dumpTax = (amount * dumpBps) / BPS;
            return amount - dumpTax;
        }

        uint256 feeAmount = (amount * token.feeRatio()) / BPS;
        if (feeAmount > amount) {
            feeAmount = amount;
        }
        return amount - feeAmount;
    }


    function _willChargeAntiDump(ICCCToken token) internal view returns (bool) {
        if (token.antiDumpActive()) {

            return block.timestamp < token.antiDumpActivatedAt() + token.ANTI_DUMP_DURATION();
        }

        uint256 ref = token.referencePrice();
        if (ref == 0) return false;
        uint256 spot = token.getTokenPriceInBnb();
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
            (uint256 reserveCCC, uint256 reserveWbnb) = _reserves();
            uint256 principalWbnb = _usdtToWbnb(buyUsdtAmount);
            uint256 recoverableWbnb = _getAmountOut(sellAmount, reserveCCC, reserveWbnb);

            if (recoverableWbnb <= principalWbnb) {
                return (sellAmount, 0);
            }

            uint256 userCanOutAmount = _getAmountIn(principalWbnb, reserveCCC, reserveWbnb);
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
