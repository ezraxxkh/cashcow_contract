pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";


contract CCTokenDistributor is Initializable, AdminRoleUpgrade {
    using SafeERC20 for IERC20;


    IERC20 public ccc;


    mapping(address => bool) public isSpender;

    error ErrorUnauthorized();


    event CccPaid(address indexed to, uint256 amount);

    modifier onlySpender() {
        if (!isSpender[msg.sender]) revert ErrorUnauthorized();
        _;
    }

    function initialize() public initializer {
        _addAdmin(msg.sender);
    }

    function setAboutAddress(
        address ccc_
    ) external onlyAdmin {
        ccc = IERC20(ccc_);
    }


    function setSpender(address account, bool status) external onlyAdmin {
        isSpender[account] = status;
    }


    function payCcc(address to, uint256 amount) external onlySpender {
        ccc.safeTransfer(to, amount);
        emit CccPaid(to, amount);
    }
}
