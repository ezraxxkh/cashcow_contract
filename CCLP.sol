// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";
import "./interfaces/IStake.sol";
import "./interfaces/IPancakeRouter02.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ICCSwap.sol";


contract CCLP is Initializable, AdminRoleUpgrade {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_SWAP_SLIPPAGE_BPS = 500;

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;


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

    error ErrorOnlyLedger();
    error ErrorZeroAmount();
    error ErrorExchangeNotConfigured();
    error ErrorInsufficientCcc();
    error ErrorInsufficientPoolCcc();
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
        if (address(router) == address(0) || wbnb == address(0)) {
            revert ErrorExchangeNotConfigured();
        }
        if (ccSwap == address(0)) revert ErrorCcSwapNotSet();


        ICCSwap(ccSwap).addUserBuyUSDT(user, usdtAmount);

        uint256 deadline = block.timestamp;


        paymentToken.forceApprove(address(router), usdtAmount);
        uint256 wbnbBefore = IERC20(wbnb).balanceOf(address(this));
        router.swapExactTokensForTokens(usdtAmount, 0, pathUsdtToBnb, address(this), deadline);
        uint256 wbnbGot = IERC20(wbnb).balanceOf(address(this)) - wbnbBefore;
        if (wbnbGot == 0) revert ErrorSwapFailed();


        uint256 wbnbForCcc = wbnbGot / 2;
        uint256 wbnbForLp = wbnbGot - wbnbForCcc;
        uint256 cccBefore = ccc.balanceOf(address(this));
        uint256 quotedCcc = router.getAmountsOut(wbnbForCcc, pathBnbToCcc)[1];
        uint256 minCccOut = (quotedCcc * (BPS - MAX_SWAP_SLIPPAGE_BPS)) / BPS;
        if (minCccOut == 0) revert ErrorSwapFailed();
        IERC20(wbnb).forceApprove(address(router), wbnbForCcc);
        router.swapExactTokensForTokens(wbnbForCcc, minCccOut, pathBnbToCcc, address(this), deadline);
        uint256 cccGot = ccc.balanceOf(address(this)) - cccBefore;
        if (cccGot == 0) revert ErrorSwapFailed();


        IERC20(wbnb).forceApprove(address(router), wbnbForLp);
        ccc.forceApprove(address(router), cccGot);
        (uint256 amountWbnb, uint256 amountCcc, uint256 liquidity) = router.addLiquidity(
            wbnb,
            address(ccc),
            wbnbForLp,
            cccGot,
            0,
            0,
            DEAD_ADDRESS,
            deadline
        );

        emit MinerLiquidityAdded(user, usdtAmount, amountWbnb, amountCcc, liquidity);
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

        if (v2WbnbCcc == address(0) || ccc.balanceOf(v2WbnbCcc) < cccNet) {
            revert ErrorInsufficientPoolCcc();
        }

        treasury.payCcc(user, cccNet);
        if (ccSwap == address(0)) revert ErrorCcSwapNotSet();
        ICCSwap(ccSwap).withdrawFromPair(address(treasury), cccNet);
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
