pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "./AdminRoleUpgrade.sol";
import "./CCLedger.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/ICCAllowed.sol";

contract CCReward is AdminRoleUpgrade, Initializable {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using ECDSAUpgradeable for bytes32;

    address public ccc;
    address public rewardSigner;
    CCLedger public ledger;

    mapping(address => uint256) public nonce;

    mapping(address => uint256) public nodeTradeAmount;

    mapping(address => uint256) public nodeProfitAmount;

    mapping(address => uint256) public builderTradeAmount;

    mapping(address => uint256) public builderProfitAmount;

    mapping(address => uint256) public builderMarketRewardAmount;

    mapping(address => uint256) public communityExchangeFeeAmount;

    mapping(address => uint256) public communityTradeAmount;

    mapping(address => uint256) public communityProfitAmount;

    mapping(address => uint256) public directRewardAmount;

    ITreasury public treasury;

    ICCAllowed public allowed;

    error ErrorLimited();

    event ClaimNodeReward(address indexed user, uint256 reduceTradeAmount, uint256 reduceProfitAmount);
    event ClaimBuilderReward(
        address indexed user,
        uint256 reduceTradeAmount,
        uint256 reduceProfitAmount,
        uint256 reduceMarketRewardAmount
    );
    event ClaimCommunityReward(
        address indexed user,
        uint256 reduceExchangeFeeAmount,
        uint256 reduceTradeAmount,
        uint256 reduceProfitAmount
    );
    event ClaimDirectReward(address indexed user, uint256 reduceDirectRewardAmount);

    function initialize() public initializer {

        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setAbountAddress(address _ccc, address _ledger, address _treasury) external onlyAdmin {
        ccc = _ccc;
        ledger = CCLedger(_ledger);

        treasury = ITreasury(_treasury);
    }

    function setAllowed(address _allowed) external onlyAdmin {
        allowed = ICCAllowed(_allowed);
    }

    function setRewardSigner(address _rewardSigner) external onlyAdmin {
        rewardSigner = _rewardSigner;
    }

    function _checkNotLimited(address user) internal view {
        if (address(allowed) != address(0) && allowed.isLimited(user)) revert ErrorLimited();
    }

    function claimNodeReward(uint256 _tradeAmount, uint256 _profitAmount, uint256 signedBlock, bytes calldata signature) external {
        _checkNotLimited(msg.sender);
        _verifyNodeSignature(msg.sender, _tradeAmount, _profitAmount, signedBlock, signature);

        require(_tradeAmount >= nodeTradeAmount[msg.sender], "trade amount not enough");
        require(_profitAmount >= nodeProfitAmount[msg.sender], "profit amount not enough");

        uint256 reduceTradeAmount = _tradeAmount - nodeTradeAmount[msg.sender];
        uint256 reduceProfitAmount = _profitAmount - nodeProfitAmount[msg.sender];
        require(reduceTradeAmount > 0 || reduceProfitAmount > 0, "nothing to claim");

        nodeTradeAmount[msg.sender] = _tradeAmount;
        nodeProfitAmount[msg.sender] = _profitAmount;

        treasury.payCcc(msg.sender, reduceTradeAmount.add(reduceProfitAmount));

        emit ClaimNodeReward(msg.sender, reduceTradeAmount, reduceProfitAmount);
    }

    function _verifyNodeSignature(address user, uint256 _tradeAmount, uint256 _profitAmount, uint256 signedBlock, bytes calldata signature) internal {

        require(rewardSigner != address(0), "signer unset");
        require(block.number + 50 >= signedBlock, "future block");
        require(signedBlock + 1000 >= block.number, "expired");

        require(_verifyNodeSig(user, _tradeAmount, _profitAmount, signedBlock, signature) == rewardSigner, "bad signature");
        nonce[user] = nonce[user].add(1);
    }

    function _verifyNodeSig(
        address user, uint256 _tradeAmount, uint256 _profitAmount, uint256 signedBlock, bytes calldata signature
    ) public view returns(address)  {

        bytes32 messageHash = keccak256(
            abi.encodePacked(user, _tradeAmount, _profitAmount, signedBlock,"ccreward_nonce", nonce[user])
        );
        return (messageHash.toEthSignedMessageHash().recover(signature));

    }

    function claimBuilderReward(
        uint256 _tradeAmount,
        uint256 _profitAmount,
        uint256 _marketRewardAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) external {
        _checkNotLimited(msg.sender);
        _verifyBuilderSignature(msg.sender, _tradeAmount, _profitAmount, _marketRewardAmount, signedBlock, signature);

        require(_tradeAmount >= builderTradeAmount[msg.sender], "trade amount not enough");
        require(_profitAmount >= builderProfitAmount[msg.sender], "profit amount not enough");
        require(_marketRewardAmount >= builderMarketRewardAmount[msg.sender], "market amount not enough");

        uint256 reduceTradeAmount = _tradeAmount - builderTradeAmount[msg.sender];
        uint256 reduceProfitAmount = _profitAmount - builderProfitAmount[msg.sender];
        uint256 reduceMarketRewardAmount = _marketRewardAmount - builderMarketRewardAmount[msg.sender];

        require(reduceTradeAmount > 0 || reduceProfitAmount > 0 || reduceMarketRewardAmount > 0, "nothing to claim");

        builderTradeAmount[msg.sender] = _tradeAmount;
        builderProfitAmount[msg.sender] = _profitAmount;
        builderMarketRewardAmount[msg.sender] = _marketRewardAmount;

        treasury.payCcc(msg.sender, reduceTradeAmount.add(reduceProfitAmount));

        ledger.addCash(msg.sender, reduceMarketRewardAmount, 4, address(this));

        emit ClaimBuilderReward(msg.sender, reduceTradeAmount, reduceProfitAmount, reduceMarketRewardAmount);
    }

    function claimCommunityReward(
        uint256 _exchangeFeeAmount,
        uint256 _tradeAmount,
        uint256 _profitAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) external {
        _checkNotLimited(msg.sender);
        _verifyCommunitySignature(msg.sender, _exchangeFeeAmount, _tradeAmount, _profitAmount, signedBlock, signature);

        require(_exchangeFeeAmount >= communityExchangeFeeAmount[msg.sender], "exchange fee amount not enough");
        require(_tradeAmount >= communityTradeAmount[msg.sender], "trade amount not enough");
        require(_profitAmount >= communityProfitAmount[msg.sender], "profit amount not enough");

        uint256 reduceExchangeFeeAmount = _exchangeFeeAmount - communityExchangeFeeAmount[msg.sender];
        uint256 reduceTradeAmount = _tradeAmount - communityTradeAmount[msg.sender];
        uint256 reduceProfitAmount = _profitAmount - communityProfitAmount[msg.sender];

        require(reduceExchangeFeeAmount > 0 || reduceTradeAmount > 0 || reduceProfitAmount > 0, "nothing to claim");

        communityExchangeFeeAmount[msg.sender] = _exchangeFeeAmount;
        communityTradeAmount[msg.sender] = _tradeAmount;
        communityProfitAmount[msg.sender] = _profitAmount;

        treasury.payCcc(msg.sender, reduceTradeAmount.add(reduceProfitAmount));

        ledger.addCash(msg.sender, reduceExchangeFeeAmount, 6, address(this));

        emit ClaimCommunityReward(msg.sender, reduceExchangeFeeAmount, reduceTradeAmount, reduceProfitAmount);
    }

    function claimDirectReward(
        uint256 _directRewardAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) external {
        _checkNotLimited(msg.sender);
        _verifyDirectSignature(msg.sender, _directRewardAmount, signedBlock, signature);

        require(_directRewardAmount >= directRewardAmount[msg.sender], "direct amount not enough");

        uint256 reduceDirectRewardAmount = _directRewardAmount - directRewardAmount[msg.sender];
        require(reduceDirectRewardAmount > 0, "nothing to claim");

        directRewardAmount[msg.sender] = _directRewardAmount;

        ledger.addCash(msg.sender, reduceDirectRewardAmount, 5, address(this));
        emit ClaimDirectReward(msg.sender, reduceDirectRewardAmount);
    }

    function _verifyBuilderSignature(
        address user,
        uint256 _tradeAmount,
        uint256 _profitAmount,
        uint256 _marketRewardAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) internal {
        require(rewardSigner != address(0), "signer unset");
        require(block.number + 50 >= signedBlock, "future block");
        require(signedBlock + 1000 >= block.number, "expired");

        require(
            _verifyBuilderSig(user, _tradeAmount, _profitAmount, _marketRewardAmount, signedBlock, signature) == rewardSigner,
            "bad signature"
        );
        nonce[user] = nonce[user].add(1);
    }

    function _verifyBuilderSig(
        address user,
        uint256 _tradeAmount,
        uint256 _profitAmount,
        uint256 _marketRewardAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) public view returns (address) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                user,
                _tradeAmount,
                _profitAmount,
                _marketRewardAmount,
                signedBlock,
                "ccreward_builder_nonce",
                nonce[user]
            )
        );
        return (messageHash.toEthSignedMessageHash().recover(signature));
    }

    function _verifyCommunitySignature(
        address user,
        uint256 _exchangeFeeAmount,
        uint256 _tradeAmount,
        uint256 _profitAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) internal {
        require(rewardSigner != address(0), "signer unset");
        require(block.number + 50 >= signedBlock, "future block");
        require(signedBlock + 1000 >= block.number, "expired");

        require(
            _verifyCommunitySig(user, _exchangeFeeAmount, _tradeAmount, _profitAmount, signedBlock, signature) == rewardSigner,
            "bad signature"
        );
        nonce[user] = nonce[user].add(1);
    }

    function _verifyCommunitySig(
        address user,
        uint256 _exchangeFeeAmount,
        uint256 _tradeAmount,
        uint256 _profitAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) public view returns (address) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                user,
                _exchangeFeeAmount,
                _tradeAmount,
                _profitAmount,
                signedBlock,
                "ccreward_community_nonce",
                nonce[user]
            )
        );
        return (messageHash.toEthSignedMessageHash().recover(signature));
    }

    function _verifyDirectSignature(
        address user,
        uint256 _directRewardAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) internal {
        require(rewardSigner != address(0), "signer unset");
        require(block.number + 50 >= signedBlock, "future block");
        require(signedBlock + 1000 >= block.number, "expired");

        require(_verifyDirectSig(user, _directRewardAmount, signedBlock, signature) == rewardSigner, "bad signature");
        nonce[user] = nonce[user].add(1);
    }

    function _verifyDirectSig(
        address user,
        uint256 _directRewardAmount,
        uint256 signedBlock,
        bytes calldata signature
    ) public view returns (address) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                user,
                _directRewardAmount,
                signedBlock,
                "ccreward_direct_nonce",
                nonce[user]
            )
        );
        return (messageHash.toEthSignedMessageHash().recover(signature));
    }

    function getUserNodeReward(address user) public view returns(uint256, uint256) {
        return (nodeTradeAmount[user], nodeProfitAmount[user]);
    }

    function getUserBuilderReward(address user) public view returns(uint256, uint256, uint256) {
        return (builderTradeAmount[user], builderProfitAmount[user], builderMarketRewardAmount[user]);
    }

    function getUserCommunityReward(address user) public view returns(uint256, uint256, uint256) {
        return (communityExchangeFeeAmount[user], communityTradeAmount[user], communityProfitAmount[user]);
    }

    function getUserDirectReward(address user) public view returns(uint256) {
        return directRewardAmount[user];
    }

    function setUserNodeReward(address user, uint256 _tradeAmount, uint256 _profitAmount) external onlyAdmin {
        nodeTradeAmount[user] = _tradeAmount;
        nodeProfitAmount[user] = _profitAmount;
    }

    function setUserBuilderReward(address user, uint256 _tradeAmount, uint256 _profitAmount, uint256 _marketRewardAmount) external onlyAdmin {
        builderTradeAmount[user] = _tradeAmount;
        builderProfitAmount[user] = _profitAmount;
        builderMarketRewardAmount[user] = _marketRewardAmount;
    }

    function setUserCommunityReward(address user, uint256 _exchangeFeeAmount, uint256 _tradeAmount, uint256 _profitAmount) external onlyAdmin {
        communityExchangeFeeAmount[user] = _exchangeFeeAmount;
        communityTradeAmount[user] = _tradeAmount;
        communityProfitAmount[user] = _profitAmount;
    }

    function setUserDirectReward(address user, uint256 _directRewardAmount) external onlyAdmin {
        directRewardAmount[user] = _directRewardAmount;
    }
}
