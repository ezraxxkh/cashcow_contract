// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";

contract CCLPReserve is AdminRoleUpgrade, Initializable {
    using SafeERC20 for IERC20;

    IERC20 public ccc;
    address public lpModule;

    bool private _initialized;

    error ErrorUnauthorized();
    error ErrorZeroAddress();
    error ErrorZeroAmount();
    error ErrorAlreadyInitialized();

    event CccDeposited(address indexed from, uint256 amount);
    event LpModuleUpdated(address indexed lpModule);
    event CccProvided(address indexed to, uint256 amount);

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
        ccc = IERC20(0xCbd8Bb97b9FC45D548a66e513cd5b2649BD14CCC);
        lpModule = 0x224891fbD7E4F8a89c8f8ebFBd7207bb386Fa13f;
    }

    function setAboutAddress(address lpModule_, address _ccc) external onlyAdmin {
        lpModule = lpModule_;
        ccc = IERC20(_ccc);
    }

    function provideForLiquidity(address to, uint256 amount) external {
        if (msg.sender != lpModule) revert ErrorUnauthorized();
        if (to == address(0)) revert ErrorZeroAddress();
        if (amount == 0) revert ErrorZeroAmount();
        ccc.safeTransfer(to, amount);
        emit CccProvided(to, amount);
    }
}
