pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast
    );
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function sync() external;
}

interface IUniswapV2Router {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;


}

contract CCCToken is ERC20, ERC20Permit, AccessControl, Pausable {
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    bytes32 public constant TOKEN_MANAGER = keccak256("TOKEN_MANAGER");
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant ROUTER_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant BNB_USDT_POOL = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;

    uint256 public constant BPS = 10000;
    uint256 public constant FEE_ALLOT_THRESHOLD = 1000e18;
    uint256 public constant ANTI_DUMP_BURN_BPS = 2500;
    uint256 public constant ANTI_DUMP_FEE_BPS = 500;
    uint256 public constant ANTI_DUMP_DROP_BPS = 500;
    uint256 public constant ANTI_DUMP_DURATION = 24 hours;


    uint256 public constant FEE_COBUILDER_BPS = 200;
    uint256 public constant FEE_COMMUNITY_BPS = 100;
    uint256 public constant FEE_NODE_BPS = 100;
    uint256 public constant FEE_OPS_BPS = 100;

    uint256 public lpPoolMaxUsdtValue = 20_000_000e18;
    uint256 public feeRatio = 500;
    uint256 public feeDown;
    uint256 public feeBuy;
    uint256 public feeSell;

    address public coBuilderReceiver;
    address public communityReceiver;
    address public nodeReceiver;
    address public opsReceiver;


    uint256 public referencePrice;
    uint256 public lastDay;

    bool public antiDumpActive;
    uint256 public antiDumpActivatedAt;

    bool public cccIsToken0;
    address public mainPair;

    uint256 public liqDetectMinWbnb = 1e13;

    address public treasury;
    bool private _refilling;
    mapping(address => bool) public isExcluded;


    mapping(address => bool) public tradingWhitelist;

    address public ccSwap;


    event TradingFeeCharged(
        address indexed user,
        bool isBuy,
        uint256 feeAmount
    );

    event FeeReceiverUpdated(string role, address indexed receiver);


    event AntiDumpActivated(uint256 spotPrice, uint256 referencePrice_);


    event AntiDumpDeactivated(uint256 spotPrice);


    event AntiDumpFeeCharged(
        address indexed user,
        uint256 sellAmount,
        uint256 burnAmount,
        uint256 feeAmount
    );


    event ReferencePriceUpdated(uint256 indexed day, uint256 referencePrice_);

    event TreasuryUpdated(address indexed account);

    event TradingWhitelistUpdated(address indexed account, bool enabled);

    event CcSwapUpdated(address indexed account);

    event TreasuryRefilled(address indexed treasury, uint256 amount);

    event FeeAllotted(uint256 allotTime, uint256 allotAmount);

    event LiqDetectMinWbnbUpdated(uint256 amount);

    error ErrorCallerNotManager();
    error ErrorAddressZero();
    error ErrorUnauthorized();
    error ErrorMainPairNotSet();
    error ErrorInsufficientPoolBalance();
    error ErrorTreasuryNotSet();
    error ErrorInvalidTreasury();

    constructor() ERC20("CashCowCoin Token", "CCC") ERC20Permit("CashCowCoin Token") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(TOKEN_MANAGER, msg.sender);
        _grantRole(GOVERNOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);

        _approve(address(this), address(ROUTER_V2), type(uint256).max);
        _mint(msg.sender, 1000000000000000000000000000);

    }


    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }


    function setFeeRatio(uint256 feeRatio_) external onlyRole(GOVERNOR_ROLE) {
        feeRatio = feeRatio_;
    }

    function setCoBuilderReceiver(address receiver_) external onlyRole(GOVERNOR_ROLE) {
        if (receiver_ == address(0)) revert ErrorAddressZero();
        coBuilderReceiver = receiver_;
        _setExcluded(receiver_, true);
        emit FeeReceiverUpdated("COBUILDER", receiver_);
    }

    function setCommunityReceiver(address receiver_) external onlyRole(GOVERNOR_ROLE) {
        if (receiver_ == address(0)) revert ErrorAddressZero();
        communityReceiver = receiver_;
        _setExcluded(receiver_, true);
        emit FeeReceiverUpdated("COMMUNITY", receiver_);
    }

    function setNodeReceiver(address receiver_) external onlyRole(GOVERNOR_ROLE) {
        if (receiver_ == address(0)) revert ErrorAddressZero();
        nodeReceiver = receiver_;
        _setExcluded(receiver_, true);
        emit FeeReceiverUpdated("NODE", receiver_);
    }

    function setOpsReceiver(address receiver_) external onlyRole(GOVERNOR_ROLE) {
        if (receiver_ == address(0)) revert ErrorAddressZero();
        opsReceiver = receiver_;
        _setExcluded(receiver_, true);
        emit FeeReceiverUpdated("OPS", receiver_);
    }


    function setLpPoolMaxUsdtValue(uint256 lpPoolMaxUsdtValue_) external onlyRole(GOVERNOR_ROLE) {
        lpPoolMaxUsdtValue = lpPoolMaxUsdtValue_;
    }

    function setLiqDetectMinWbnb(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        liqDetectMinWbnb = amount;
        emit LiqDetectMinWbnbUpdated(amount);
    }

    function setMainPair(address pair) external onlyRole(GOVERNOR_ROLE) {
        require(pair != address(0), "pair zero address");


        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        require(token0 == address(this) || token1 == address(this), "pair missing CCC");
        require(token0 == WBNB || token1 == WBNB, "pair missing WBNB");

        cccIsToken0 = token0 == address(this);
        mainPair = pair;
    }

    function setTreasury(address account) external onlyRole(TOKEN_MANAGER) {
        if (account == address(0)) revert ErrorAddressZero();
        treasury = account;
        _setExcluded(account, true);
        emit TreasuryUpdated(account);
    }

    function setTradingWhitelist(address account, bool enabled) external onlyRole(GOVERNOR_ROLE) {
        if (account == address(0)) revert ErrorAddressZero();
        tradingWhitelist[account] = enabled;
        emit TradingWhitelistUpdated(account, enabled);
    }

    function setCcSwap(address account) external onlyRole(TOKEN_MANAGER) {
        if (account == address(0)) revert ErrorAddressZero();
        ccSwap = account;
        tradingWhitelist[account] = true;
        emit CcSwapUpdated(account);
        emit TradingWhitelistUpdated(account, true);
    }


    function withdrawFromPair(address to, uint256 amount) external {
        if (msg.sender != ccSwap) revert ErrorUnauthorized();
        if (mainPair == address(0)) revert ErrorMainPairNotSet();
        if (to != treasury && to != DEAD_ADDRESS) revert ErrorInvalidTreasury();
        if (treasury == address(0) && to != DEAD_ADDRESS) revert ErrorTreasuryNotSet();
        if (amount == 0) revert ErrorAddressZero();

        uint256 pairBal = balanceOf(mainPair);
        if (pairBal < amount) revert ErrorInsufficientPoolBalance();

        _refilling = true;
        super._transfer(mainPair, to, amount);
        _refilling = false;

        IUniswapV2Pair(mainPair).sync();
        emit TreasuryRefilled(to, amount);
    }


    function getTokenPriceInBnb() public view returns (uint256) {
        require(mainPair != address(0), "main pair not set");
        return _getPairPrice(mainPair, address(this), 1e18);
    }


    function getTokenPriceInUsdt() public view returns (uint256) {
        uint256 bnbPrice = getTokenPriceInBnb();
        if (bnbPrice == 0) return 0;
        uint256 bnbInUsdt = _getPairPrice(BNB_USDT_POOL, WBNB, 1e18);
        return (bnbPrice * bnbInUsdt) / 1e18;
    }


    function getMainPairUsdtValue() public view returns (uint256) {
        if (mainPair == address(0)) return 0;

        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(mainPair).getReserves();
        uint256 cccReserve = cccIsToken0 ? reserve0 : reserve1;
        uint256 bnbReserve = cccIsToken0 ? reserve1 : reserve0;

        uint256 bnbInUsdt = _getPairPrice(BNB_USDT_POOL, WBNB, 1e18);
        uint256 bnbValueUsdt = (bnbReserve * bnbInUsdt) / 1e18;
        uint256 cccValueUsdt = (cccReserve * getTokenPriceInUsdt()) / 1e18;

        return bnbValueUsdt + cccValueUsdt;
    }


    function isLpPoolAboveBuyThreshold() public view returns (bool) {
        return getMainPairUsdtValue() > lpPoolMaxUsdtValue;
    }


    function _getPairPrice(
        address pair,
        address tokenIn,
        uint256 amountIn
    ) internal view returns (uint256) {
        address token0 = IUniswapV2Pair(pair).token0();
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return
            tokenIn == token0
                ? (amountIn * uint256(reserve1)) / uint256(reserve0)
                : (amountIn * uint256(reserve0)) / uint256(reserve1);
    }


    function setExcluded(address account, bool enabled) external onlyRole(GOVERNOR_ROLE) {
        require(account != address(0), "account zero address");

        if (!enabled) {
            require(
                account != address(this),
                "core address must stay excluded"
            );
        }
        _setExcluded(account, enabled);
    }

    function _setExcluded(address account, bool enabled) internal {
        isExcluded[account] = enabled;

    }

    function _updateTokenPrice() internal {


        if (mainPair == address(0)) {
            return;
        }
        uint256 nowDay_ = block.timestamp / 86400;
        if (nowDay_ > lastDay) {
            uint256 nowPrice_ = getTokenPriceInBnb();
            if (nowPrice_ > 0) {
                lastDay = nowDay_;
                referencePrice = nowPrice_;
                emit ReferencePriceUpdated(nowDay_, nowPrice_);
            }
        }
    }


    function _checkAntiDump() internal {
        if (antiDumpActive) {
            if (block.timestamp >= antiDumpActivatedAt + ANTI_DUMP_DURATION) {
                antiDumpActive = false;
                emit AntiDumpDeactivated(getTokenPriceInBnb());
            }
            return;
        }
        if (referencePrice == 0) {
            return;
        }
        uint256 spot = getTokenPriceInBnb();
        if (spot == 0) {
            return;
        }
        uint256 floor = referencePrice * (BPS - ANTI_DUMP_DROP_BPS) / BPS;
        if (spot < floor) {
            antiDumpActive = true;
            antiDumpActivatedAt = block.timestamp;
            emit AntiDumpActivated(spot, referencePrice);
        }
    }


    function _takeAntiDumpSellFee(
        address from,
        address user,
        uint256 amount
    ) internal returns (uint256) {
        uint256 burnAmount = amount * ANTI_DUMP_BURN_BPS / BPS;
        uint256 feeAmount = amount * ANTI_DUMP_FEE_BPS / BPS;
        if (burnAmount + feeAmount > amount) {
            burnAmount = amount;
            feeAmount = 0;
        }
        if (burnAmount > 0) {
            super._transfer(from, DEAD_ADDRESS, burnAmount);
            feeDown += burnAmount;
        }
        if (feeAmount > 0) {
            _takeFee(from, user, feeAmount, false);
        }
        if (burnAmount > 0 || feeAmount > 0) {
            emit AntiDumpFeeCharged(user, amount, burnAmount, feeAmount);
        }
        return amount - burnAmount - feeAmount;
    }


    function _isAddLiquidity(address to) internal view returns (bool) {
        if (to != mainPair || mainPair == address(0)) {
            return false;
        }
        (, uint256 reserveWbnb) = _reserves();
        uint256 wbnbBal = IERC20(WBNB).balanceOf(mainPair);
        return wbnbBal >= reserveWbnb + liqDetectMinWbnb;
    }


    function _isRemoveLiquidity(address from) internal view returns (bool) {
        if (from != mainPair || mainPair == address(0)) {
            return false;
        }
        (, uint256 reserveWbnb) = _reserves();
        uint256 wbnbBal = IERC20(WBNB).balanceOf(mainPair);

        if (cccIsToken0) {


            return wbnbBal <= reserveWbnb + liqDetectMinWbnb;
        }

        return reserveWbnb >= wbnbBal + liqDetectMinWbnb;
    }

    function _reserves() internal view returns (uint256 reserveCCC, uint256 reserveWbnb) {
        if (mainPair == address(0)) {
            return (0, 0);
        }
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(mainPair).getReserves();
        if (cccIsToken0) {
            reserveCCC = uint256(r0);
            reserveWbnb = uint256(r1);
        } else {
            reserveCCC = uint256(r1);
            reserveWbnb = uint256(r0);
        }
    }


    function _calcTradingFee(uint256 amount) internal view returns (uint256) {
        if (amount == 0 || feeRatio == 0) {
            return 0;
        }
        return (amount * feeRatio) / BPS;
    }

    function _sendFeeShare(address from, address receiver, uint256 amount) internal {
        if (amount == 0) return;
        address to = receiver == address(0) ? DEAD_ADDRESS : receiver;
        super._transfer(from, to, amount);
        if (to == DEAD_ADDRESS) {
            feeDown += amount;
        }
    }

    function _takeFee(
        address from,
        address user,
        uint256 feeAmount,
        bool isBuy
    ) internal {
        if (feeAmount == 0) {
            return;
        }

        super._transfer(from, address(this), feeAmount);
        if (isBuy) {
            feeBuy += feeAmount;
        } else {
            feeSell += feeAmount;
        }
        emit TradingFeeCharged(user, isBuy, feeAmount);
    }


    function _allotFee() internal {
        uint256 amount_ = 0;
        uint256 cobuilderAmount_ = 0;
        uint256 communityAmount_ = 0;
        uint256 nodeAmount_ = 0;
        uint256 opsAmount_ = 0;

        uint256 tradingShareTotal = FEE_COBUILDER_BPS + FEE_COMMUNITY_BPS + FEE_NODE_BPS + FEE_OPS_BPS;

        uint256 feeBuy_ = feeBuy;
        uint256 feeSell_ = feeSell;
        uint256 tradingFee_ = feeBuy_ + feeSell_;
        if (tradingFee_ >= FEE_ALLOT_THRESHOLD) {
            amount_ += tradingFee_;
            uint256 cobuilderAmt = tradingFee_ * FEE_COBUILDER_BPS / tradingShareTotal;
            uint256 communityAmt = tradingFee_ * FEE_COMMUNITY_BPS / tradingShareTotal;
            uint256 nodeAmt = tradingFee_ * FEE_NODE_BPS / tradingShareTotal;
            cobuilderAmount_ += cobuilderAmt;
            communityAmount_ += communityAmt;
            nodeAmount_ += nodeAmt;
            opsAmount_ += tradingFee_ - cobuilderAmt - communityAmt - nodeAmt;
            feeBuy = 0;
            feeSell = 0;
        }

        if (amount_ == 0) {
            return;
        }

        _sendFeeShare(address(this), coBuilderReceiver, cobuilderAmount_);
        _sendFeeShare(address(this), communityReceiver, communityAmount_);
        _sendFeeShare(address(this), opsReceiver, opsAmount_);
        _sendFeeShare(address(this), nodeReceiver, nodeAmount_);

        emit FeeAllotted(block.timestamp, amount_);
    }


    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {

        if (_refilling) {
            super._transfer(from, to, amount);
            return;
        }

        _updateTokenPrice();


        if (to == mainPair && isExcluded[from]) {
            super._transfer(from, to, amount);
            return;
        }


        bool addLiquidityTx = _isAddLiquidity(to);
        bool removeLiquidityTx = _isRemoveLiquidity(from);


        if (addLiquidityTx || removeLiquidityTx) {
            super._transfer(from, to, amount);
            return;
        }


        if (from == mainPair || to == mainPair) {
            address other = from == mainPair ? to : from;
            require(
                tradingWhitelist[other] || isExcluded[other],
                "not trading whitelist"
            );
        }


        bool buyTx = from == mainPair && !isExcluded[to] && !removeLiquidityTx;

        bool sellTx = to == mainPair && !isExcluded[from] && !addLiquidityTx;

        if (buyTx) {
            require(isLpPoolAboveBuyThreshold(), "lp pool below buy threshold");
            uint256 feeAmount = _calcTradingFee(amount);
            if (feeAmount > amount) {
                feeAmount = amount;
            }
            _takeFee(from, to, feeAmount, true);
            uint256 sendAmount = amount - feeAmount;
            super._transfer(from, to, sendAmount);
            return;
        }

        if (sellTx) {
            _checkAntiDump();
            uint256 sendAmount;
            if (antiDumpActive) {

                sendAmount = _takeAntiDumpSellFee(from, from, amount);
            } else {
                uint256 feeAmount = _calcTradingFee(amount);
                if (feeAmount > amount) {
                    feeAmount = amount;
                }
                _takeFee(from, from, feeAmount, false);
                sendAmount = amount - feeAmount;
            }

            _allotFee();
            super._transfer(from, to, sendAmount);
            return;
        }

        super._transfer(from, to, amount);
    }
}
