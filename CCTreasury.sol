// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";


contract CCTreasury is Initializable, AdminRoleUpgrade {
    using SafeERC20 for IERC20;


    IERC20 public paymentToken;

    IERC20 public ccc;

    address public machine;

    address public lp;

    mapping(address => bool) public isSpender;

    error ErrorUnauthorized();


    event CccPaid(address indexed to, uint256 amount);
    event SpenderUpdated(address indexed account, bool status);

    modifier onlySpender() {
        if (!isSpender[msg.sender]) revert ErrorUnauthorized();
        _;
    }

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setAboutAddress(
        address paymentToken_,
        address ccc_,
        address machine_,
        address lp_
    ) external onlyAdmin {
        paymentToken = IERC20(paymentToken_);
        ccc = IERC20(ccc_);
        machine = machine_;
        lp = lp_;
    }


    function setSpender(address account, bool status) external onlyAdmin {
        isSpender[account] = status;
        emit SpenderUpdated(account, status);
    }


    function payCcc(address to, uint256 amount) external onlySpender {
        ccc.safeTransfer(to, amount);
        emit CccPaid(to, amount);
    }
}
