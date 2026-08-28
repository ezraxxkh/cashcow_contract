// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";


contract CCOperationsTreasury is Initializable, AdminRoleUpgrade {
    using SafeERC20 for IERC20;


    IERC20 public ccc;


    function initialize() public initializer {
       _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setAboutAddress(address ccc_) external onlyAdmin {
        ccc = IERC20(ccc_);
    }


}
