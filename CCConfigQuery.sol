pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./AdminRoleUpgrade.sol";

interface ICCLP {
    function exchangeFeeBps(address user) external view returns (uint256);
    function exchangeFeeRate(address user) external view returns (uint256 feeBps, uint8 tier);
}

contract CCConfigQuery is Initializable, AdminRoleUpgrade {

    ICCLP public lp;

    function initialize() public initializer {
        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
    }

    function setAboutAddress(address lp_) external onlyAdmin {
        lp = ICCLP(lp_);
    }

    function exchangeFeeBps(address user) external view returns (uint256) {
        return lp.exchangeFeeBps(user);
    }

    function exchangeFeeRate(address user) external view returns (uint256 feeBps, uint8 tier) {
        return lp.exchangeFeeRate(user);
    }
}
