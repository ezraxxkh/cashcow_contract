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
    function sync() external;
}

interface IUniswapV2Router {
    function factory() external pure returns (address);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract CCCToken is ERC20, ERC20Permit, AccessControl, Pausable {
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant ROUTER_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant BNB_USDT_POOL = 0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE;

    uint256 public constant BPS = 10000;
    uint256 public constant ANTI_DUMP_BURN_BPS = 2500;
    uint256 public constant ANTI_DUMP_FEE_BPS = 500;
    uint256 public constant ANTI_DUMP_DROP_BPS = 500;
    uint256 public constant ANTI_DUMP_DURATION = 24 hours;

    uint256 public constant FEE_COBUILDER_BPS = 200;
    uint256 public constant FEE_COMMUNITY_BPS = 100;
    uint256 public constant FEE_NODE_BPS = 100;
    uint256 public constant FEE_OPS_BPS = 100;

    uint256 public lpPoolMaxUsdtValue = 20_000_000e18;
    uint256 public buyFeeRatio = 500;
    uint256 public sellFeeRatio = 500;
    uint256 public feeDown;
    uint256 public feeBuy;
    uint256 public feeSell;
    bool public freeTradingEnabled;

    bool public burnEnabled;

    address public coBuilderReceiver;
    address public communityReceiver;
    address public nodeReceiver;
    address public opsReceiver;

    struct PairInfo {
        bool enabled;
        bool cccIsToken0;
        bool antiDumpActive;
        address quoteToken;
        uint32 lastDay;
        uint40 antiDumpActivatedAt;
        uint256 referencePrice;
    }

    mapping(address => bool) public isPair;
    mapping(address => PairInfo) public pairs;
    address[] public pairList;
    address public mainPair;

    address public treasury;
    mapping(address => bool) public isExcluded;

    mapping(address => bool) public tradingWhitelist;
    address public ccSwap;
    mapping(address => bool) public isCcSwap;

    event TradingFeeCharged(
        address indexed user,
        bool isBuy,
        uint256 feeAmount
    );
    event FeeReceiverUpdated(string role, address indexed receiver);
    event AntiDumpActivated(address indexed pair, uint256 spotPrice, uint256 referencePrice_);
    event AntiDumpDeactivated(address indexed pair, uint256 spotPrice);
    event AntiDumpFeeCharged(
        address indexed pair,
        address indexed user,
        uint256 sellAmount,
        uint256 burnAmount,
        uint256 feeAmount
    );
    event ReferencePriceUpdated(address indexed pair, uint256 indexed day, uint256 referencePrice_);
    event TreasuryRefilled(address indexed treasury, uint256 amount);

    error ErrorAddressZero();
    error ErrorUnauthorized();
    error ErrorInsufficientPoolBalance();
    error ErrorTreasuryNotSet();
    error ErrorInvalidTreasury();
    error ErrorPairDisabled();
    error ErrorPairNotRegistered();
    error ErrorPairAlreadyRegistered();
    error ErrorBurnDisabled();

    constructor() ERC20("CashCowCoin", "CCC") ERC20Permit("CashCowCoin") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNOR_ROLE, msg.sender);
        _grantRole(GUARDIAN_ROLE, msg.sender);

        _mint(0x45391271372d8011A21e7C2cC991C4A491BB9643, 168_000_000e18);
        _mint(0x4BEFAFe12617E8c88D4F0a8E58035cd6CaE76bC1, 21_000_000e18);
        _mint(0x5ce95Ea6DaB093e08cc62A7C08242B2eB301DBd1, 10_500_000e18);
        _mint(0x4444C1C876DDEa4afD4eC8c2f3cb3f723DEF8c2E, 10_500_000e18);

        isExcluded[0x45391271372d8011A21e7C2cC991C4A491BB9643] = true;
        isExcluded[0x4BEFAFe12617E8c88D4F0a8E58035cd6CaE76bC1] = true;
        isExcluded[0x5ce95Ea6DaB093e08cc62A7C08242B2eB301DBd1] = true;
        isExcluded[0x4444C1C876DDEa4afD4eC8c2f3cb3f723DEF8c2E] = true;
        isExcluded[0xae48015BBCAd9B5DE945a2423Aee0D2c434a795d] = true;
        address factory = IUniswapV2Router(ROUTER_V2).factory();
        address pair = IUniswapV2Factory(factory).createPair(address(this), WBNB);
        _registerPair(pair);
        mainPair = pair;

    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function setBuyFeeRatio(uint256 buyFeeRatio_) external onlyRole(GOVERNOR_ROLE) {
        buyFeeRatio = buyFeeRatio_;
    }

    function setSellFeeRatio(uint256 sellFeeRatio_) external onlyRole(GOVERNOR_ROLE) {
        sellFeeRatio = sellFeeRatio_;
    }

    function setFeeReceivers(
        address coBuilder_,
        address community_,
        address ops_,
        address node_
    ) external onlyRole(GOVERNOR_ROLE) {
        if (
            coBuilder_ == address(0) ||
            community_ == address(0) ||
            ops_ == address(0) ||
            node_ == address(0)
        ) {
            revert ErrorAddressZero();
        }
        coBuilderReceiver = coBuilder_;
        communityReceiver = community_;
        opsReceiver = ops_;
        nodeReceiver = node_;
        emit FeeReceiverUpdated("COBUILDER", coBuilder_);
        emit FeeReceiverUpdated("COMMUNITY", community_);
        emit FeeReceiverUpdated("OPS", ops_);
        emit FeeReceiverUpdated("NODE", node_);
    }

    function setLpPoolMaxUsdtValue(uint256 lpPoolMaxUsdtValue_) external onlyRole(GOVERNOR_ROLE) {
        lpPoolMaxUsdtValue = lpPoolMaxUsdtValue_;
    }

    function setFreeTradingEnabled(bool enabled) external onlyRole(GOVERNOR_ROLE) {
        freeTradingEnabled = enabled;
    }

    function setBurnEnabled(bool enabled) external onlyRole(GOVERNOR_ROLE) {
        burnEnabled = enabled;
    }

    function registerPair(address pair) external onlyRole(GOVERNOR_ROLE) {
        _registerPair(pair);
    }

    function _registerPair(address pair) internal {
        if (pair == address(0)) revert ErrorAddressZero();
        if (isPair[pair]) revert ErrorPairAlreadyRegistered();

        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        bool cccIsToken0_ = token0 == address(this);
        require(cccIsToken0_ || token1 == address(this), "pair missing ccc");
        address quoteToken = cccIsToken0_ ? token1 : token0;

        isPair[pair] = true;
        PairInfo storage info = pairs[pair];
        info.enabled = true;
        info.cccIsToken0 = cccIsToken0_;
        info.quoteToken = quoteToken;
        pairList.push(pair);
    }

    function setPairEnabled(address pair, bool enabled) external onlyRole(GOVERNOR_ROLE) {
        if (!isPair[pair]) revert ErrorPairNotRegistered();
        pairs[pair].enabled = enabled;
    }

    function setMainPair(address pair) external onlyRole(GOVERNOR_ROLE) {
        if (!isPair[pair]) revert ErrorPairNotRegistered();
        require(pairs[pair].quoteToken == WBNB, "pair missing wbnb");
        mainPair = pair;
    }

    function setTreasury(address account) external onlyRole(GOVERNOR_ROLE) {
        if (account == address(0)) revert ErrorAddressZero();
        treasury = account;
    }

    function setTradingWhitelist(address account, bool enabled) external onlyRole(GOVERNOR_ROLE) {
        if (account == address(0)) revert ErrorAddressZero();
        tradingWhitelist[account] = enabled;
    }

    function setCcSwap(address account) external onlyRole(GOVERNOR_ROLE) {
        if (account == address(0)) revert ErrorAddressZero();
        ccSwap = account;
        isCcSwap[account] = true;
        tradingWhitelist[account] = true;
    }

    function setCcSwapModule(address account, bool enabled) external onlyRole(GOVERNOR_ROLE) {
        if (account == address(0)) revert ErrorAddressZero();
        isCcSwap[account] = enabled;
        tradingWhitelist[account] = enabled;
    }

    function withdrawFromPair(address to, uint256 amount) external {
        _withdrawFromPair(mainPair, to, amount);
    }

    function withdrawFromPairAt(address pair, address to, uint256 amount) external {
        _withdrawFromPair(pair, to, amount);
    }

    function _withdrawFromPair(address pair, address to, uint256 amount) internal {
        if (!isCcSwap[msg.sender]) revert ErrorUnauthorized();
        if (!isPair[pair]) revert ErrorPairNotRegistered();
        if (to != treasury && to != DEAD_ADDRESS) revert ErrorInvalidTreasury();
        if (treasury == address(0) && to != DEAD_ADDRESS) revert ErrorTreasuryNotSet();
        if (amount == 0) revert ErrorAddressZero();
        if (to == DEAD_ADDRESS && !isBurnAllowed()) revert ErrorBurnDisabled();

        uint256 pairBal = balanceOf(pair);
        if (pairBal < amount) revert ErrorInsufficientPoolBalance();

        super._transfer(pair, to, amount);

        IUniswapV2Pair(pair).sync();
        emit TreasuryRefilled(to, amount);
    }

    function getTokenPriceInBnb() public view returns (uint256) {
        return _getPairPrice(mainPair, address(this), 1e18);
    }

    function getTokenPriceInUsdt() public view returns (uint256) {
        uint256 bnbPrice = getTokenPriceInBnb();
        if (bnbPrice == 0) return 0;
        uint256 bnbInUsdt = _getPairPrice(BNB_USDT_POOL, WBNB, 1e18);
        return (bnbPrice * bnbInUsdt) / 1e18;
    }

    function getMainPairSingleSideUsdtValue() public view returns (uint256) {
        uint256 reserveWbnb = _reserveQuote(mainPair, pairs[mainPair].cccIsToken0);
        uint256 bnbInUsdt = _getPairPrice(BNB_USDT_POOL, WBNB, 1e18);
        return (reserveWbnb * bnbInUsdt) / 1e18;
    }

    function isLpPoolAboveBuyThreshold() public view returns (bool) {
        return getMainPairSingleSideUsdtValue() > lpPoolMaxUsdtValue;
    }

    function isBurnAllowed() public view returns (bool) {

        return burnEnabled || getMainPairSingleSideUsdtValue() < lpPoolMaxUsdtValue;
    }

    function getPairPriceInQuote(address pair) public view returns (uint256) {
        if (!isPair[pair]) return 0;
        return _getPairPrice(pair, address(this), 1e18);
    }

    function getPairReserves(address pair) public view returns (uint256 reserveCcc, uint256 reserveQuote) {
        if (!isPair[pair]) return (0, 0);
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        if (pairs[pair].cccIsToken0) {
            return (uint256(r0), uint256(r1));
        }
        return (uint256(r1), uint256(r0));
    }

    function pairAntiDumpState(address pair)
        external
        view
        returns (bool active, uint256 activatedAt, uint256 referencePrice_)
    {
        PairInfo storage info = pairs[pair];
        return (info.antiDumpActive, uint256(info.antiDumpActivatedAt), info.referencePrice);
    }

    function pairQuoteToken(address pair) external view returns (address) {
        return pairs[pair].quoteToken;
    }

    function pairCount() external view returns (uint256) {
        return pairList.length;
    }

    function cccIsToken0() external view returns (bool) {
        return pairs[mainPair].cccIsToken0;
    }

    function referencePrice() external view returns (uint256) {
        return pairs[mainPair].referencePrice;
    }

    function antiDumpActive() external view returns (bool) {
        return pairs[mainPair].antiDumpActive;
    }

    function antiDumpActivatedAt() external view returns (uint256) {
        return uint256(pairs[mainPair].antiDumpActivatedAt);
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
        isExcluded[account] = enabled;
    }

    function _updateTokenPrice(address pair, PairInfo storage info) internal {
        uint32 nowDay_ = uint32(block.timestamp / 86400);
        if (nowDay_ > info.lastDay) {
            uint256 nowPrice_ = _getPairPrice(pair, address(this), 1e18);
            if (nowPrice_ > 0) {
                info.lastDay = nowDay_;
                info.referencePrice = nowPrice_;
                emit ReferencePriceUpdated(pair, nowDay_, nowPrice_);
            }
        }
    }

    function _checkAntiDump(address pair, PairInfo storage info) internal {
        if (info.antiDumpActive) {
            if (block.timestamp >= uint256(info.antiDumpActivatedAt) + ANTI_DUMP_DURATION) {
                info.antiDumpActive = false;
                emit AntiDumpDeactivated(pair, _getPairPrice(pair, address(this), 1e18));
            }
            return;
        }
        uint256 refPrice = info.referencePrice;
        if (refPrice == 0) {
            return;
        }
        uint256 spot = _getPairPrice(pair, address(this), 1e18);
        if (spot == 0) {
            return;
        }
        uint256 floor = refPrice * (BPS - ANTI_DUMP_DROP_BPS) / BPS;
        if (spot < floor) {
            info.antiDumpActive = true;
            info.antiDumpActivatedAt = uint40(block.timestamp);
            emit AntiDumpActivated(pair, spot, refPrice);
        }
    }

    function _takeAntiDumpSellFee(
        address pair,
        address from,
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
            _takeFee(from, from, feeAmount, false);
        }
        if (burnAmount > 0 || feeAmount > 0) {
            emit AntiDumpFeeCharged(pair, from, amount, burnAmount, feeAmount);
        }
        return amount - burnAmount - feeAmount;
    }

    function _reserveQuote(address pair, bool cccIsToken0_) internal view returns (uint256) {
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        return cccIsToken0_ ? uint256(r1) : uint256(r0);
    }

    function _calcTradingFee(uint256 amount, bool isBuy) internal view returns (uint256) {
        uint256 ratio = isBuy ? buyFeeRatio : sellFeeRatio;
        if (amount == 0 || ratio == 0) {
            return 0;
        }
        return (amount * ratio) / BPS;
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

        uint256 shareTotal = FEE_COBUILDER_BPS + FEE_COMMUNITY_BPS + FEE_NODE_BPS + FEE_OPS_BPS;
        uint256 cobuilderAmount_ = feeAmount * FEE_COBUILDER_BPS / shareTotal;
        uint256 communityAmount_ = feeAmount * FEE_COMMUNITY_BPS / shareTotal;
        uint256 nodeAmount_ = feeAmount * FEE_NODE_BPS / shareTotal;
        uint256 opsAmount_ = feeAmount - cobuilderAmount_ - communityAmount_ - nodeAmount_;

        if (coBuilderReceiver == communityReceiver && communityReceiver == nodeReceiver) {
            _sendFeeShare(from, coBuilderReceiver, cobuilderAmount_ + communityAmount_ + nodeAmount_);
        } else {
            _sendFeeShare(from, coBuilderReceiver, cobuilderAmount_);
            _sendFeeShare(from, communityReceiver, communityAmount_);
            _sendFeeShare(from, nodeReceiver, nodeAmount_);
        }
        _sendFeeShare(from, opsReceiver, opsAmount_);

        if (isBuy) {
            feeBuy += feeAmount;
        } else {
            feeSell += feeAmount;
        }

        emit TradingFeeCharged(user, isBuy, feeAmount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override whenNotPaused {
        address pair = isPair[to] ? to : (isPair[from] ? from : address(0));

        if (pair == address(0)) {
            super._transfer(from, to, amount);
            return;
        }

        PairInfo storage info = pairs[pair];
        _updateTokenPrice(pair, info);

        if (isExcluded[from] || isExcluded[to]) {
            super._transfer(from, to, amount);
            return;
        }

        if (!info.enabled) {
            address whitelistAccount = pair == from ? to : from;
            if (!tradingWhitelist[whitelistAccount]) {
                revert ErrorPairDisabled();
            }
        }

        address other = pair == from ? to : from;
        require(tradingWhitelist[other], "not trading whitelist");

        bool buyTx = pair == from;

        if (buyTx) {
            if (pair == mainPair) {
                require(freeTradingEnabled, "free trading disabled");
                require(isLpPoolAboveBuyThreshold(), "lp pool below buy threshold");
            }
            uint256 feeAmount = _calcTradingFee(amount, true);
            if (feeAmount > amount) {
                feeAmount = amount;
            }
            _takeFee(from, to, feeAmount, true);
            uint256 sendAmount = amount - feeAmount;
            super._transfer(from, to, sendAmount);
            return;
        }

        if (pair == to) {
            _checkAntiDump(pair, info);
            uint256 sendAmount;
            if (info.antiDumpActive) {
                sendAmount = _takeAntiDumpSellFee(pair, from, amount);
            } else {
                uint256 feeAmount = _calcTradingFee(amount, false);
                if (feeAmount > amount) {
                    feeAmount = amount;
                }
                _takeFee(from, from, feeAmount, false);
                sendAmount = amount - feeAmount;
            }
            super._transfer(from, to, sendAmount);
            return;
        }

        super._transfer(from, to, amount);
    }
}
