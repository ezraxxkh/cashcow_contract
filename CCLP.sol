// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";
import "./interfaces/IStake.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ICCSwap.sol";
import "./interfaces/ICCCToken.sol";
import "./interfaces/ICCLPReserve.sol";
import "./interfaces/ICLPoolManager.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract CCLP is Initializable, AdminRoleUpgrade {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant USDT_WBNB_SLIPPAGE_BPS = 50;
    uint256 internal constant WBNB_CCC_SLIPPAGE_BPS = 50;
    uint256 internal constant ADD_LIQUIDITY_SLIPPAGE_BPS = 1000;
    uint256 internal constant SLIPPAGE_USDT_THRESHOLD_C4 = 5000e18;
    uint256 internal constant ADD_LIQUIDITY_SLIPPAGE_C4_BPS = 3000;
    uint256 internal constant SLIPPAGE_USDT_THRESHOLD_C5 = 10000e18;
    uint256 internal constant ADD_LIQUIDITY_SLIPPAGE_C5_BPS = 5000;
    uint256 internal constant SLIPPAGE_USDT_THRESHOLD_C6 = 50000e18;
    uint256 internal constant ADD_LIQUIDITY_SLIPPAGE_C6_BPS = 9500;

    uint256 internal constant TARGET_BASE_USDT_PER_CCC = 300000000000000000;
    uint256 internal constant TARGET_START_TS = 1788652800;
    uint256 internal constant DAILY_TARGET_GROWTH_BPS = 500;
    uint256 internal constant TARGET_MAX_DAYS = 2800;

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    address internal constant REFILL_V2_WBNB_CCC = 0xb76a465A47c777492c9667cA020c32C94d7C09de;
    address internal constant REFILL_V2_UUSD_CCC = 0xF58270B4293f6654C0b154B659F44E78586560cd;
    address internal constant REFILL_V2_ANOME_CCC = 0x821AAE29E9D02D26AaA6aD8cD52E80B74b3bAbbf;

    address internal constant CL_POOL_MANAGER = 0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b;
    bytes32 internal constant ANOME_USDT_CL_POOL_ID =
        0x95195e794ea913b7032aea488986ae28587b736c5c0180be748a4cdece455fea;

    uint8 internal constant REFILL_POOL_COUNT = 3;

    enum RefillQuoteMode {
        V2Wbnb,
        PeggedUusd,
        InfinityAnome
    }

    address public ledger;
    IStake public stake;
    IPancakeRouter02 public router;
    IERC20 public ccc;
    IERC20 public paymentToken;
    ITreasury public treasury;
    address public wbnb;
    address[] internal pathUsdtToBnb;
    address[] internal pathBnbToCcc;
    address public v2UsdtWbnb;
    address public v2WbnbCcc;

    address public machine;
    address public lpRecipient;
    address public ccSwap;
    address public cccReserve;
    uint256 public cachedTargetPrice;
    uint256 public cachedTargetDay;

    error ErrorOnlyLedger();
    error ErrorZeroAmount();
    error ErrorExchangeNotConfigured();
    error ErrorInsufficientCcc();
    error ErrorInsufficientPoolCcc();
    error ErrorInsufficientReserveCcc();
    error ErrorInvalidRoute();
    error ErrorOnlyMachine();
    error ErrorSwapFailed();
    error ErrorCcSwapNotSet();

    event MinerLiquidityAdded(
        address indexed user,
        uint256 usdtAmount,
        uint256 wbnbAdded,
        uint256 cccAdded,
        uint256 liquidity
    );

    event TreasuryRefilledFromPool(address indexed pair, uint256 amount);

    modifier onlyLedger() {
        if (msg.sender != ledger) revert ErrorOnlyLedger();
        _;
    }

    modifier onlyMachine() {
        if (msg.sender != machine) revert ErrorOnlyMachine();
        _;
    }

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setAboutAddress(
        address ledger_,
        address stake_,
        address router_,
        address ccc_,
        address paymentToken_,
        address treasury_,
        address machine_,
        address ccSwap_
    ) external onlyAdmin {
        ledger = ledger_;
        stake = IStake(stake_);
        router = IPancakeRouter02(router_);
        ccc = IERC20(ccc_);
        paymentToken = IERC20(paymentToken_);
        treasury = ITreasury(treasury_);
        machine = machine_;
        if (ccSwap_ == address(0)) revert ErrorCcSwapNotSet();
        ccSwap = ccSwap_;
    }

    function setCccReserve(address cccReserve_) external onlyAdmin {
        if (cccReserve_ == address(0)) revert ErrorExchangeNotConfigured();
        cccReserve = cccReserve_;
    }

    function setExchangeRoutes(
        address wbnb_,
        address[] calldata usdtToBnb,
        address[] calldata bnbToCcc,
        address v2UsdtWbnb_,
        address v2WbnbCcc_
    ) external onlyAdmin {
        if (usdtToBnb.length != 2 || usdtToBnb[0] != address(paymentToken) || usdtToBnb[1] != wbnb_) {
            revert ErrorInvalidRoute();
        }
        if (bnbToCcc.length != 2 || bnbToCcc[0] != wbnb_ || bnbToCcc[1] != address(ccc)) {
            revert ErrorInvalidRoute();
        }
        if (v2UsdtWbnb_ == address(0) || v2WbnbCcc_ == address(0)) {
            revert ErrorExchangeNotConfigured();
        }
        wbnb = wbnb_;
        pathUsdtToBnb = usdtToBnb;
        pathBnbToCcc = bnbToCcc;
        v2UsdtWbnb = v2UsdtWbnb_;
        v2WbnbCcc = v2WbnbCcc_;
    }

    function setLpRecipient(address lpRecipient_) external onlyAdmin {
        lpRecipient = lpRecipient_;
    }

    function onMinerPurchase(address user, uint256 usdtAmount) external onlyMachine {
        if (usdtAmount == 0) revert ErrorZeroAmount();
        if (
            address(router) == address(0) || wbnb == address(0) || v2WbnbCcc == address(0)
                || v2UsdtWbnb == address(0) || pathBnbToCcc.length != 2
        ) {
            revert ErrorExchangeNotConfigured();
        }
        if (ccSwap == address(0)) revert ErrorCcSwapNotSet();

        ICCSwap(ccSwap).addUserBuyUSDT(user, usdtAmount);

        uint256 deadline = block.timestamp;

        paymentToken.forceApprove(address(router), usdtAmount);
        uint256 quotedWbnb = router.getAmountsOut(usdtAmount, pathUsdtToBnb)[1];
        uint256 minWbnbOut = (quotedWbnb * (BPS - USDT_WBNB_SLIPPAGE_BPS)) / BPS;
        if (minWbnbOut == 0) revert ErrorSwapFailed();
        uint256 wbnbBefore = IERC20(wbnb).balanceOf(address(this));
        router.swapExactTokensForTokens(usdtAmount, minWbnbOut, pathUsdtToBnb, address(this), deadline);
        uint256 wbnbGot = IERC20(wbnb).balanceOf(address(this)) - wbnbBefore;
        if (wbnbGot == 0) revert ErrorSwapFailed();

        if (_cccSpotPriceUsdt() < _syncTargetPrice()) {
            _addMinerLiquidityViaZap(user, usdtAmount, wbnbGot, deadline);
        } else {
            _addMinerLiquidityViaReserve(user, usdtAmount, wbnbGot, deadline);
        }
    }

    function cccSpotPriceUsdt() external view returns (uint256) {
        return _cccSpotPriceUsdt();
    }

    function targetPriceUsdt() external view returns (uint256) {
        return _targetPriceUsdt();
    }

    function exchange(address user, uint256 cashAmount)
        external
        onlyLedger
        returns (uint256 cccNet, uint256 feeAmount)
    {
        if (cashAmount == 0) revert ErrorZeroAmount();

        uint256 feeBps = exchangeFeeBps(user);
        feeAmount = (cashAmount * feeBps) / BPS;
        uint256 netCash = cashAmount - feeAmount;
        cccNet = quoteCashToCcc(netCash);

        if (ccc.balanceOf(address(treasury)) < cccNet) revert ErrorInsufficientCcc();

        treasury.payCcc(user, cccNet);
        if (ccSwap == address(0)) revert ErrorCcSwapNotSet();
        _refillTreasuryFromCheapestPool(cccNet);
    }

    function totalRefillPoolCcc() external view returns (uint256) {
        return _totalRefillPoolCcc();
    }

    function getCCCPriceByWBNB() external view returns (uint256) {
        return _cccPriceUsdtInPool(0);
    }

    function getCCCPriceByUUSD() external view returns (uint256) {
        return _cccPriceUsdtInPool(1);
    }

    function getCCCPriceByAnome() external view returns (uint256) {
        return _cccPriceUsdtInPool(2);
    }

    function getCheapestRefillPair() external view returns (address) {
        return _refillPoolAddress(_cheapestRefillPoolIndex());
    }

    function exchangeFeeBps(address user) public view returns (uint256) {
        return _feeBpsForPrincipal(_activePrincipal(user));
    }

    function exchangeFeeRate(address user) external view returns (uint256 feeBps, uint8 tier) {
        uint256 principal = _activePrincipal(user);
        feeBps = _feeBpsForPrincipal(principal);
        tier = _tierForPrincipal(principal);
    }

    function previewCashToCCC(address user, uint256 amount)
        external
        view
        returns (uint256 cccAmount, uint256 feeAmount, uint256 feeBps)
    {
        if (amount == 0) revert ErrorZeroAmount();
        feeBps = exchangeFeeBps(user);
        feeAmount = (amount * feeBps) / BPS;
        uint256 netCash = amount - feeAmount;
        cccAmount = quoteCashToCcc(netCash);
    }

    function quoteCashToCcc(uint256 cashAmount) public view returns (uint256) {
        if (cashAmount == 0) return 0;
        if (address(router) == address(0) || wbnb == address(0)) {
            revert ErrorExchangeNotConfigured();
        }

        uint256 bnbAmount = router.getAmountsOut(cashAmount, pathUsdtToBnb)[1];
        return router.getAmountsOut(bnbAmount, pathBnbToCcc)[1];
    }

    function _addMinerLiquidityViaZap(address user, uint256 usdtAmount, uint256 wbnbGot, uint256 deadline)
        internal
    {
        uint256 wbnbHalf = wbnbGot / 2;
        if (wbnbHalf == 0) revert ErrorSwapFailed();

        IERC20(wbnb).forceApprove(address(router), wbnbHalf);
        uint256 quotedCcc = router.getAmountsOut(wbnbHalf, pathBnbToCcc)[1];
        uint256 minCccOut = (quotedCcc * (BPS - WBNB_CCC_SLIPPAGE_BPS)) / BPS;
        if (minCccOut == 0) revert ErrorSwapFailed();
        uint256 cccBefore = ccc.balanceOf(address(this));
        router.swapExactTokensForTokens(wbnbHalf, minCccOut, pathBnbToCcc, address(this), deadline);
        uint256 cccGot = ccc.balanceOf(address(this)) - cccBefore;
        if (cccGot == 0) revert ErrorSwapFailed();

        uint256 wbnbForLp = wbnbGot - wbnbHalf;
        IERC20(wbnb).forceApprove(address(router), wbnbForLp);
        ccc.forceApprove(address(router), cccGot);
        uint256 slippageBps = _addLiquiditySlippageBps(usdtAmount);
        uint256 minWbnbForLp = (wbnbForLp * (BPS - slippageBps)) / BPS;
        uint256 minCccForLp = (cccGot * (BPS - slippageBps)) / BPS;
        (uint256 amountWbnb, uint256 amountCcc, uint256 liquidity) = router.addLiquidity(
            wbnb,
            address(ccc),
            wbnbForLp,
            cccGot,
            minWbnbForLp,
            minCccForLp,
            DEAD_ADDRESS,
            deadline
        );

        emit MinerLiquidityAdded(user, usdtAmount, amountWbnb, amountCcc, liquidity);
    }

    function _addMinerLiquidityViaReserve(address user, uint256 usdtAmount, uint256 wbnbGot, uint256 deadline)
        internal
    {
        if (cccReserve == address(0)) revert ErrorExchangeNotConfigured();

        (uint256 reserveCcc, uint256 reserveWbnb) = ICCCToken(address(ccc)).getPairReserves(v2WbnbCcc);
        if (reserveWbnb == 0 || reserveCcc == 0) revert ErrorSwapFailed();
        uint256 cccRequired = Math.mulDiv(wbnbGot, reserveCcc, reserveWbnb);
        if (cccRequired == 0) revert ErrorSwapFailed();
        if (ccc.balanceOf(cccReserve) < cccRequired) revert ErrorInsufficientReserveCcc();
        ICCLPReserve(cccReserve).provideForLiquidity(address(this), cccRequired);

        IERC20(wbnb).forceApprove(address(router), wbnbGot);
        ccc.forceApprove(address(router), cccRequired);
        uint256 slippageBps = _addLiquiditySlippageBps(usdtAmount);
        uint256 minWbnbForLp = (wbnbGot * (BPS - slippageBps)) / BPS;
        uint256 minCccForLp = (cccRequired * (BPS - slippageBps)) / BPS;
        (uint256 amountWbnb, uint256 amountCcc, uint256 liquidity) = router.addLiquidity(
            wbnb,
            address(ccc),
            wbnbGot,
            cccRequired,
            minWbnbForLp,
            minCccForLp,
            DEAD_ADDRESS,
            deadline
        );

        emit MinerLiquidityAdded(user, usdtAmount, amountWbnb, amountCcc, liquidity);
    }

    function _cccSpotPriceUsdt() internal view returns (uint256) {
        if (v2WbnbCcc == address(0) || v2UsdtWbnb == address(0) || wbnb == address(0)) {
            revert ErrorExchangeNotConfigured();
        }
        (uint256 reserveCcc, uint256 reserveWbnb) = ICCCToken(address(ccc)).getPairReserves(v2WbnbCcc);
        if (reserveCcc == 0 || reserveWbnb == 0) return 0;

        uint256 wbnbPerCcc = Math.mulDiv(reserveWbnb, 1e18, reserveCcc);
        uint256 usdtPerWbnb = _getPairPrice(v2UsdtWbnb, wbnb, 1e18);
        if (usdtPerWbnb == 0) return 0;
        return Math.mulDiv(wbnbPerCcc, usdtPerWbnb, 1e18);
    }

    function _daysElapsed() internal view returns (uint256 daysElapsed) {
        if (block.timestamp <= TARGET_START_TS) return 0;
        daysElapsed = (block.timestamp - TARGET_START_TS) / 1 days;
        if (daysElapsed > TARGET_MAX_DAYS) daysElapsed = TARGET_MAX_DAYS;
    }

    function _computeTargetFromBase(uint256 daysElapsed) internal pure returns (uint256 price) {
        price = TARGET_BASE_USDT_PER_CCC;
        for (uint256 i = 0; i < daysElapsed; ) {
            price = Math.mulDiv(price, BPS + DAILY_TARGET_GROWTH_BPS, BPS);
            unchecked {
                ++i;
            }
        }
    }

    function _targetPriceUsdt() internal view returns (uint256) {
        uint256 today = _daysElapsed();
        if (cachedTargetPrice != 0 && cachedTargetDay == today) {
            return cachedTargetPrice;
        }
        return _computeTargetFromBase(today);
    }

    function _syncTargetPrice() internal returns (uint256) {
        uint256 today = _daysElapsed();
        if (cachedTargetPrice != 0 && cachedTargetDay == today) {
            return cachedTargetPrice;
        }

        uint256 price;
        if (cachedTargetPrice != 0 && cachedTargetDay < today) {
            price = cachedTargetPrice;
            uint256 delta = today - cachedTargetDay;
            for (uint256 i = 0; i < delta; ) {
                price = Math.mulDiv(price, BPS + DAILY_TARGET_GROWTH_BPS, BPS);
                unchecked {
                    ++i;
                }
            }
        } else {
            price = _computeTargetFromBase(today);
        }

        cachedTargetPrice = price;
        cachedTargetDay = today;
        return price;
    }

    function _totalRefillPoolCcc() internal view returns (uint256 total) {
        for (uint8 i = 0; i < REFILL_POOL_COUNT; ) {
            total += ccc.balanceOf(_refillPoolAddress(i));
            unchecked {
                ++i;
            }
        }
    }

    function _refillTreasuryFromCheapestPool(uint256 amount) internal {
        uint8 cheapest = _cheapestRefillPoolIndex();
        address pair = _refillPoolAddress(cheapest);
        if (ccc.balanceOf(pair) < amount) revert ErrorInsufficientPoolCcc();

        ICCSwap(ccSwap).withdrawFromPairAt(pair, address(treasury), amount);
        emit TreasuryRefilledFromPool(pair, amount);
    }

    function _cheapestRefillPoolIndex() internal view returns (uint8 best) {
        uint256 bestPrice = type(uint256).max;
        for (uint8 i = 0; i < REFILL_POOL_COUNT; ) {
            uint256 price = _cccPriceUsdtInPool(i);
            if (price < bestPrice) {
                bestPrice = price;
                best = i;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _cccPriceUsdtInPool(uint8 index) internal view returns (uint256) {
        address pair = _refillPoolAddress(index);
        (uint256 reserveCcc, uint256 reserveQuote) = ICCCToken(address(ccc)).getPairReserves(pair);
        if (reserveCcc == 0) return type(uint256).max;

        uint256 quotePerCcc = Math.mulDiv(reserveQuote, 1e18, reserveCcc);
        uint256 usdtPerQuote = _usdtPerQuote(_refillQuoteMode(index));
        if (usdtPerQuote == 0) return type(uint256).max;

        return Math.mulDiv(quotePerCcc, usdtPerQuote, 1e18);
    }

    function _usdtPerQuote(RefillQuoteMode mode) internal view returns (uint256) {
        if (mode == RefillQuoteMode.PeggedUusd) {
            return 1e18;
        }
        if (mode == RefillQuoteMode.V2Wbnb) {
            return _getPairPrice(v2UsdtWbnb, wbnb, 1e18);
        }
        return _usdtPerAnomeFromCl();
    }

    function _usdtPerAnomeFromCl() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = ICLPoolManager(CL_POOL_MANAGER).getSlot0(ANOME_USDT_CL_POOL_ID);
        if (sqrtPriceX96 == 0) return 0;

        return Math.mulDiv(Math.mulDiv(1e18, 1 << 96, uint256(sqrtPriceX96)), 1 << 96, uint256(sqrtPriceX96));
    }

    function _getPairPrice(address pair, address tokenIn, uint256 amountIn) internal view returns (uint256) {
        address token0 = IUniswapV2Pair(pair).token0();
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return
            tokenIn == token0
                ? Math.mulDiv(amountIn, uint256(reserve1), uint256(reserve0))
                : Math.mulDiv(amountIn, uint256(reserve0), uint256(reserve1));
    }

    function _refillPoolAddress(uint8 index) internal pure returns (address) {
        if (index == 0) return REFILL_V2_WBNB_CCC;
        if (index == 1) return REFILL_V2_UUSD_CCC;
        return REFILL_V2_ANOME_CCC;
    }

    function _refillQuoteMode(uint8 index) internal pure returns (RefillQuoteMode) {
        if (index == 0) return RefillQuoteMode.V2Wbnb;
        if (index == 1) return RefillQuoteMode.PeggedUusd;
        return RefillQuoteMode.InfinityAnome;
    }

    function _addLiquiditySlippageBps(uint256 usdtAmount) internal pure returns (uint256) {
        if (usdtAmount >= SLIPPAGE_USDT_THRESHOLD_C6) return ADD_LIQUIDITY_SLIPPAGE_C6_BPS;
        if (usdtAmount >= SLIPPAGE_USDT_THRESHOLD_C5) return ADD_LIQUIDITY_SLIPPAGE_C5_BPS;
        if (usdtAmount >= SLIPPAGE_USDT_THRESHOLD_C4) return ADD_LIQUIDITY_SLIPPAGE_C4_BPS;
        return ADD_LIQUIDITY_SLIPPAGE_BPS;
    }

    function _activePrincipal(address user) internal view returns (uint256) {
        if (address(stake) == address(0)) return 0;
        return stake.activePrincipalSum(user);
    }

    function _feeBpsForPrincipal(uint256 principal) internal pure returns (uint256) {
        if (principal >= 25_000e18) return 1000;
        if (principal >= 10_000e18) return 1500;
        if (principal >= 5_000e18) return 2000;
        if (principal >= 1_000e18) return 2500;
        return 3000;
    }

    function _tierForPrincipal(uint256 principal) internal pure returns (uint8) {
        if (principal >= 25_000e18) return 5;
        if (principal >= 10_000e18) return 4;
        if (principal >= 5_000e18) return 3;
        if (principal >= 1_000e18) return 2;
        return 1;
    }
}
