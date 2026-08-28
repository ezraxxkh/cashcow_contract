// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";
import "./interfaces/IRelation.sol";
import "./interfaces/ILedger.sol";
import "./interfaces/ICCSwap.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./libraries/V3PositionMath.sol";


contract CCEarlyBird is Initializable, AdminRoleUpgrade, IERC721Receiver {
    using SafeERC20 for IERC20;


    enum Tier {
        B1,
        B2,
        B3,
        B4,
        B5
    }


    struct TierConfig {
        uint256 price;
        uint256 maxSupply;
        uint256 sold;
        uint8 communityLevel;
        uint16 recashBonusRate;
    }


    IERC20 public paymentToken;


    mapping(Tier => TierConfig) public tiers;

    mapping(address => bool) public hasPurchased;

    mapping(address => Tier) public purchaserTier;


    IRelation public relation;

    ILedger public ledger;


    INonfungiblePositionManager internal constant POSITION_MANAGER =
        INonfungiblePositionManager(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364);

    address public liquidityPool;

    int24 public constant TICK_LOWER = 1390;

    int24 public constant TICK_UPPER = 1820;

    uint256 public positionTokenId;

    mapping(address => uint256) public purchaseTime;

    mapping(address => uint256) public pendingReferralRewards;

    uint256 public purchaseStartTime;

    uint256 internal constant PURCHASE_END_TIME = 1787738400;

    mapping(address => bool) public whitelist;

    mapping(address => Tier[]) public purchasedTiers;

    mapping(address => mapping(Tier => uint256)) public tierPurchaseTime;

    ICCSwap public ccSwap;

    uint256 internal constant SLIPPAGE_BPS = 9950;
    uint256 internal constant BONUS_DENOMINATOR = 10000;
    uint256 internal constant REFERRAL_BPS = 500;

    uint256 public constant MAX_PURCHASE_AMOUNT = 24000e18;

    uint256 internal constant LIQUIDITY_REMOVE_BUFFER = 1e11;
    address internal constant RELATION_ROOT = 0x0000000000000000000000000000000000000001;

    address internal constant EXTRA_B4_BUYER = 0xd9C128D978bE031B438d97ebe0827bA0393b2F0a;

    error ErrorTierAlreadyOwned();
    error ErrorExceedMaxPurchase();
    error ErrorSoldOut();
    error ErrorNotBound();
    error ErrorNoPosition();
    error ErrorLiquidityPoolNotSet();
    error ErrorArrayLengthMismatch();
    error ErrorNothingToClaim();
    error ErrorInsufficientLiquidity();
    error ErrorPurchaseNotStarted();
    error ErrorPurchaseClosed();
    error ErrorMaxSupplyBelowSold();

    uint256 internal constant DEADLINE_BUFFER = 1 hours;


    event EarlyBirdPurchased(
        address indexed buyer,
        Tier indexed tier,
        uint256 amount,
        uint256 recashAmount,
        uint8 communityLevel,
        uint256 slotIndex
    );


    event RecashBonusRateSet(Tier indexed tier, uint16 rate);


    event MaxSupplySet(Tier indexed tier, uint256 maxSupply);


    event LiquidityAdded(
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        bool isNewPosition
    );


    event LiquidityRemoved(
        uint256 indexed tokenId,
        uint128 liquidityRemoved,
        uint256 amount0,
        uint256 amount1
    );


    event ReferralRewardAccrued(
        address indexed buyer,
        address indexed referrer,
        uint256 amount
    );


    event ReferralRewardClaimed(
        address indexed referrer,
        uint256 amount
    );


    event AdminLiquidityRemoved(
        address indexed admin,
        uint256 requestedAmount,
        uint256 amount0,
        uint256 amount1
    );


    event PurchaseStartTimeSet(uint256 purchaseStartTime);


    event WhitelistSet(address indexed account, bool enabled);

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
        _addAdmin(0x906104C3Cf9ab59830830ad89ED81C0A00c71414);
        tiers[Tier.B1] = TierConfig(500e18, 2000, 0, 0, 0);
        tiers[Tier.B2] = TierConfig(2000e18, 1000, 0, 1, 0);
        tiers[Tier.B3] = TierConfig(5000e18, 600, 0, 2, 0);
        tiers[Tier.B4] = TierConfig(10000e18, 300, 0, 3, 0);
        tiers[Tier.B5] = TierConfig(20000e18, 100, 0, 4, 0);
    }

    function setAboutAddress(
        address paymentToken_,
        address relation_,
        address ledger_
    ) external onlyAdmin {
        paymentToken = IERC20(paymentToken_);
        paymentToken.forceApprove(address(POSITION_MANAGER), type(uint256).max);
        relation = IRelation(relation_);
        ledger = ILedger(ledger_);
    }


    function setLiquidityPool(address liquidityPool_) external onlyAdmin {
        liquidityPool = liquidityPool_;
    }


    function setCcSwap(address ccSwap_) external onlyAdmin {
        ccSwap = ICCSwap(ccSwap_);
    }


    function setRecashBonusRate(Tier tier, uint16 rate) external onlyAdmin {
        tiers[tier].recashBonusRate = rate;
        emit RecashBonusRateSet(tier, rate);
    }


    function setMaxSupply(Tier tier, uint256 maxSupply) external onlyAdmin {
        if (maxSupply < tiers[tier].sold) revert ErrorMaxSupplyBelowSold();
        tiers[tier].maxSupply = maxSupply;
        emit MaxSupplySet(tier, maxSupply);
    }


    function batchSetRecashBonusRate(Tier[] calldata tierList, uint16[] calldata rates) external  onlyAdmin{
        uint256 length = tierList.length;
        if (length != rates.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < length; ) {
            tiers[tierList[i]].recashBonusRate = rates[i];
            emit RecashBonusRateSet(tierList[i], rates[i]);
            unchecked {
                ++i;
            }
        }
    }


    function setPurchaseStartTime(uint256 purchaseStartTime_) external onlyAdmin {
        purchaseStartTime = purchaseStartTime_;

    }


    function setWhitelist(address account, bool enabled) external onlyAdmin {
        whitelist[account] = enabled;

    }


    function batchSetWhitelist(address[] calldata accounts, bool[] calldata enabled) external onlyAdmin {
        uint256 length = accounts.length;
        if (length != enabled.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < length; ) {
            whitelist[accounts[i]] = enabled[i];
            emit WhitelistSet(accounts[i], enabled[i]);
            unchecked {
                ++i;
            }
        }
    }


    function previewRecashAmount(Tier tier) external view returns (uint256) {
        TierConfig storage config = tiers[tier];
        return _calcRecashAmount(config.price, config.recashBonusRate);
    }


    function buy(Tier tier) external {
        require(false, "not open");
        if (block.timestamp >= PURCHASE_END_TIME) revert ErrorPurchaseClosed();
        if (purchaseStartTime != 0 && block.timestamp < purchaseStartTime && !whitelist[msg.sender]) {
            revert ErrorPurchaseNotStarted();
        }
        if (relation.Inviter(msg.sender) == address(0)) revert ErrorNotBound();
        if (_ownsTier(msg.sender, tier)) revert ErrorTierAlreadyOwned();

        TierConfig storage config = tiers[tier];
        if (config.sold >= config.maxSupply) revert ErrorSoldOut();

        uint256 spent = _totalPurchasedAmount(msg.sender);
        if (spent + config.price > MAX_PURCHASE_AMOUNT) revert ErrorExceedMaxPurchase();


        if (purchaseTime[msg.sender] != 0 && purchasedTiers[msg.sender].length == 0) {
            Tier legacyTier = purchaserTier[msg.sender];
            purchasedTiers[msg.sender].push(legacyTier);
            if (tierPurchaseTime[msg.sender][legacyTier] == 0) {
                tierPurchaseTime[msg.sender][legacyTier] = purchaseTime[msg.sender];
            }
        }

        config.sold += 1;
        if (purchaseTime[msg.sender] == 0) {
            purchaserTier[msg.sender] = tier;
            purchaseTime[msg.sender] = block.timestamp;
        }
        purchasedTiers[msg.sender].push(tier);
        tierPurchaseTime[msg.sender][tier] = block.timestamp;

        paymentToken.safeTransferFrom(msg.sender, address(this), config.price);

        uint256 referralAmount = 0;
        address referrer = _findReferralRecipient(msg.sender);
        if (referrer != address(0)) {
            referralAmount = config.price * REFERRAL_BPS / BONUS_DENOMINATOR;
            pendingReferralRewards[referrer] += referralAmount;
            emit ReferralRewardAccrued(msg.sender, referrer, referralAmount);
        }

        _addV3Liquidity(config.price);

        uint256 recashAmount = _calcRecashAmount(config.price, config.recashBonusRate);
        ledger.mint(msg.sender, recashAmount, 0);


        ccSwap.addUserBuyUSDT(msg.sender, config.price);

        emit EarlyBirdPurchased(
            msg.sender,
            tier,
            config.price,
            recashAmount,
            config.communityLevel,
            config.sold
        );
    }


    function buyByAdmin(address[] calldata accounts, Tier[] calldata tierList) external onlyAdmin {

        uint256 length = accounts.length;
        if (length != tierList.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < length; ) {
            _buyByAdmin(accounts[i], tierList[i]);
            unchecked {
                ++i;
            }
        }
    }

    function _buyByAdmin(address account, Tier tier) internal {
        if (relation.Inviter(account) == address(0)) revert ErrorNotBound();

        TierConfig storage config = tiers[tier];
        if (config.sold >= config.maxSupply) revert ErrorSoldOut();

        uint256 spent = _totalPurchasedAmount(account);
        if (spent + config.price > MAX_PURCHASE_AMOUNT) revert ErrorExceedMaxPurchase();


        if (purchaseTime[account] != 0 && purchasedTiers[account].length == 0) {
            Tier legacyTier = purchaserTier[account];
            purchasedTiers[account].push(legacyTier);
            if (tierPurchaseTime[account][legacyTier] == 0) {
                tierPurchaseTime[account][legacyTier] = purchaseTime[account];
            }
        }

        config.sold += 1;
        if (purchaseTime[account] == 0) {
            purchaserTier[account] = tier;
            purchaseTime[account] = block.timestamp;
        }
        purchasedTiers[account].push(tier);
        tierPurchaseTime[account][tier] = block.timestamp;

        uint256 recashAmount = _calcRecashAmount(config.price, config.recashBonusRate);
        ledger.mint(account, recashAmount, 0);


        ccSwap.addUserBuyUSDT(account, config.price);

        emit EarlyBirdPurchased(
            account,
            tier,
            config.price,
            recashAmount,
            config.communityLevel,
            config.sold
        );
    }


    function claimReferralReward() external {
        uint256 amount = pendingReferralRewards[msg.sender];
        if (amount == 0) revert ErrorNothingToClaim();
        pendingReferralRewards[msg.sender] = 0;

        uint256 removeAmount = amount + LIQUIDITY_REMOVE_BUFFER;
        (uint256 amount0, ) = _removeV3LiquidityForPaymentToken(removeAmount);
        if (amount0 < amount) revert ErrorInsufficientLiquidity();

        paymentToken.safeTransfer(msg.sender, amount);
        emit ReferralRewardClaimed(msg.sender, amount);
    }


    function removeLiquidity(uint256 amount) external onlyAdmin {
        uint256 removeAmount = amount + LIQUIDITY_REMOVE_BUFFER;
        (uint256 amount0, uint256 amount1) = _removeV3LiquidityForPaymentToken(removeAmount);
        if (amount0 < amount) revert ErrorInsufficientLiquidity();

        paymentToken.safeTransfer(msg.sender, amount);

        emit AdminLiquidityRemoved(msg.sender, amount, amount0, amount1);
    }


    function getPositionAmounts() external view returns (uint256 amount0, uint256 amount1) {
        if (positionTokenId == 0) return (0, 0);

        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = POSITION_MANAGER.positions(positionTokenId);

        if (liquidity == 0) return (0, 0);

        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(liquidityPool).slot0();
        uint160 sqrtRatioAX96 = V3PositionMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = V3PositionMath.getSqrtRatioAtTick(tickUpper);
        (amount0, amount1) = V3PositionMath.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
    }

    function getPositionAmountBypositionTokenId(uint256 _positionTokenId, address _pool) external view returns (uint256 amount0, uint256 amount1) {
        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            ,

        ) = POSITION_MANAGER.positions(_positionTokenId);

        if (liquidity == 0) return (0, 0);

        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(_pool).slot0();
        uint160 sqrtRatioAX96 = V3PositionMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = V3PositionMath.getSqrtRatioAtTick(tickUpper);
        (amount0, amount1) = V3PositionMath.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
    }


    function _calcRecashAmount(uint256 price, uint16 recashBonusRate) internal pure returns (uint256) {
        return price * (BONUS_DENOMINATOR + uint256(recashBonusRate)) / BONUS_DENOMINATOR;
    }


    function _ownsTier(address account, Tier tier) internal view returns (bool) {
        if (account == EXTRA_B4_BUYER && tier == Tier.B4) {
            return _tierCount(account, Tier.B4) >= 2;
        }
        Tier[] storage list = purchasedTiers[account];
        uint256 length = list.length;
        if (length > 0) {
            for (uint256 i = 0; i < length; ) {
                if (list[i] == tier) return true;
                unchecked {
                    ++i;
                }
            }
            return false;
        }
        return purchaseTime[account] != 0 && purchaserTier[account] == tier;
    }


    function _tierCount(address account, Tier tier) internal view returns (uint256 count) {
        Tier[] storage list = purchasedTiers[account];
        uint256 length = list.length;
        if (length > 0) {
            for (uint256 i = 0; i < length; ) {
                if (list[i] == tier) {
                    unchecked {
                        ++count;
                    }
                }
                unchecked {
                    ++i;
                }
            }
            return count;
        }
        if (purchaseTime[account] != 0 && purchaserTier[account] == tier) {
            return 1;
        }
        return 0;
    }


    function _totalPurchasedAmount(address account) internal view returns (uint256 total) {
        Tier[] storage list = purchasedTiers[account];
        uint256 length = list.length;
        if (length > 0) {
            for (uint256 i = 0; i < length; ) {
                total += tiers[list[i]].price;
                unchecked {
                    ++i;
                }
            }
            return total;
        }
        if (purchaseTime[account] != 0) {
            return tiers[purchaserTier[account]].price;
        }
        return 0;
    }


    function _findReferralRecipient(address buyer) internal view returns (address) {
        address upline = relation.Inviter(buyer);
        while (upline != address(0) && upline != RELATION_ROOT) {
            if (_totalPurchasedAmount(upline) > 0) {
                return upline;
            }
            upline = relation.Inviter(upline);
        }
        return address(0);
    }


    function _tierPurchaseTime(address account, Tier tier) internal view returns (uint256) {
        uint256 t = tierPurchaseTime[account][tier];
        if (t != 0) return t;
        if (purchaseTime[account] != 0 && purchaserTier[account] == tier) {
            return purchaseTime[account];
        }
        return 0;
    }


    function _removeV3LiquidityForPaymentToken(uint256 paymentAmount)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        if (positionTokenId == 0) revert ErrorNoPosition();
        if (paymentAmount == 0) return (0, 0);

        IUniswapV3Pool pool = IUniswapV3Pool(liquidityPool);
        if (address(paymentToken) != pool.token0()) revert ErrorInsufficientLiquidity();

        (
            ,
            ,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 positionLiquidity,
            ,
            ,
            ,

        ) = POSITION_MANAGER.positions(positionTokenId);
        if (positionLiquidity == 0) revert ErrorInsufficientLiquidity();

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
        uint160 sqrtRatioAX96 = V3PositionMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = V3PositionMath.getSqrtRatioAtTick(tickUpper);

        uint160 sqrtLowerForAmount0;
        uint160 sqrtUpperForAmount0 = sqrtRatioBX96;
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            sqrtLowerForAmount0 = sqrtRatioAX96;
        } else if (sqrtPriceX96 < sqrtRatioBX96) {
            sqrtLowerForAmount0 = sqrtPriceX96;
        } else {
            revert ErrorInsufficientLiquidity();
        }

        (uint256 posAmount0, ) = V3PositionMath.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            positionLiquidity
        );
        if (posAmount0 < paymentAmount) revert ErrorInsufficientLiquidity();

        uint128 liquidityToRemove = V3PositionMath.getLiquidityForAmount0(
            sqrtLowerForAmount0,
            sqrtUpperForAmount0,
            paymentAmount
        );
        if (liquidityToRemove > positionLiquidity) {
            liquidityToRemove = positionLiquidity;
        }
        if (liquidityToRemove == 0) revert ErrorInsufficientLiquidity();

        uint256 amount0Min = paymentAmount * SLIPPAGE_BPS / 10000;
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;

        POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionTokenId,
                liquidity: liquidityToRemove,
                amount0Min: amount0Min,
                amount1Min: 0,
                deadline: deadline
            })
        );

        (amount0, amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        emit LiquidityRemoved(positionTokenId, liquidityToRemove, amount0, amount1);
    }


    function _addV3Liquidity(uint256 amount) internal {
        if (liquidityPool == address(0)) revert ErrorLiquidityPoolNotSet();
        if (amount == 0) return;

        IUniswapV3Pool pool = IUniswapV3Pool(liquidityPool);

        uint256 amount0Min = amount * SLIPPAGE_BPS / 10000;
        uint256 deadline = block.timestamp + DEADLINE_BUFFER;

        if (positionTokenId == 0) {
            (uint256 tokenId, uint128 liquidity, uint256 amount0, ) = POSITION_MANAGER.mint(
                INonfungiblePositionManager.MintParams({
                    token0: pool.token0(),
                    token1: pool.token1(),
                    fee: pool.fee(),
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    amount0Desired: amount,
                    amount1Desired: 0,
                    amount0Min: amount0Min,
                    amount1Min: 0,
                    recipient: address(this),
                    deadline: deadline
                })
            );
            positionTokenId = tokenId;
            emit LiquidityAdded(tokenId, liquidity, amount0, true);
        } else {
            (uint128 liquidity, uint256 amount0, ) = POSITION_MANAGER.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: positionTokenId,
                    amount0Desired: amount,
                    amount1Desired: 0,
                    amount0Min: amount0Min,
                    amount1Min: 0,
                    deadline: deadline
                })
            );
            emit LiquidityAdded(positionTokenId, liquidity, amount0, false);
        }
    }


    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }


    function getPurchaseInfo(address account) external view returns (bool purchased, uint256 purchasedAt, Tier tier) {
        purchased = _totalPurchasedAmount(account) > 0;
        purchasedAt = purchaseTime[account];
        tier = purchaserTier[account];
    }


    function getPurchasedTiers(address account)
        external
        view
        returns (Tier[] memory tierList, uint256[] memory times)
    {
        Tier[] storage list = purchasedTiers[account];
        uint256 length = list.length;
        if (length > 0) {
            tierList = new Tier[](length);
            times = new uint256[](length);
            for (uint256 i = 0; i < length; ) {
                Tier t = list[i];
                tierList[i] = t;
                times[i] = _tierPurchaseTime(account, t);
                unchecked {
                    ++i;
                }
            }
            return (tierList, times);
        }
        if (purchaseTime[account] != 0) {
            tierList = new Tier[](1);
            times = new uint256[](1);
            tierList[0] = purchaserTier[account];
            times[0] = purchaseTime[account];
            return (tierList, times);
        }
        return (new Tier[](0), new uint256[](0));
    }


    function getTierPurchaseTime(address account, Tier tier) external view returns (uint256) {
        return _tierPurchaseTime(account, tier);
    }


    function getTotalPurchasedAmount(address account) external view returns (uint256) {
        return _totalPurchasedAmount(account);
    }


    function ownsTier(address account, Tier tier) external view returns (bool) {
        return _ownsTier(account, tier);
    }


    function canPurchase(address account) external view returns (bool) {
        if (block.timestamp >= PURCHASE_END_TIME) return false;
        if (purchaseStartTime != 0 && block.timestamp < purchaseStartTime && !whitelist[account]) {
            return false;
        }
        return _totalPurchasedAmount(account) < MAX_PURCHASE_AMOUNT;
    }

    function getTier(Tier tier) external view returns (TierConfig memory info) {
        return tiers[tier];
    }

    function getTiers(Tier[] calldata tierList) external view returns (TierConfig[] memory infos) {
        uint256 length = tierList.length;
        infos = new TierConfig[](length);
        for (uint256 i = 0; i < length; ) {
            infos[i] = tiers[tierList[i]];
            unchecked {
                ++i;
            }
        }
    }
}
