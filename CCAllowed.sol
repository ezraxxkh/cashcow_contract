pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "./AdminRoleUpgrade.sol";

contract CCAllowed is AdminRoleUpgrade, Initializable {

    mapping(address => bool) public isLimited;

    mapping(address => bool) public isWriter;

    error ErrorUnauthorized();
    error ErrorArrayLengthMismatch();

    modifier onlyAdminOrWriter() {
        if (!isAdmin(msg.sender) && !isWriter[msg.sender]) revert ErrorUnauthorized();
        _;
    }

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setWriter(address account, bool status) external onlyAdmin {
        isWriter[account] = status;
    }

    function setLimited(address account, bool status) external onlyAdminOrWriter {
        isLimited[account] = status;
    }

    function batchSetLimited(address[] calldata accounts, bool[] calldata statuses) external onlyAdminOrWriter {
        uint256 length = accounts.length;
        if (length != statuses.length) revert ErrorArrayLengthMismatch();
        for (uint256 i = 0; i < length; ) {
            isLimited[accounts[i]] = statuses[i];
            unchecked {
                ++i;
            }
        }
    }
}
