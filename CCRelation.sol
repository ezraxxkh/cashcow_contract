pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "./AdminRoleUpgrade.sol";

contract CCRelation is AdminRoleUpgrade, Initializable {
    event Bind(address parent, address child, uint256 level);
    event ReplaceBind(address oldAddr, address newAddr);
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using AddressUpgradeable for address;

    mapping(address => address) public Inviter;
    mapping(address => bool) public invStats;
    mapping(address => address[]) public invList;
    mapping(address => address[]) public activeList;

    mapping(address => uint256) public level;

    function initialize() public initializer {

        _addAdmin(0x7923ba113c5a45908Ad16410C6faaC365cB749ee);
        invStats[0x0000000000000000000000000000000000000001] = true;
        level[0x0000000000000000000000000000000000000001] = 1;
    }

    function replaceBind(address oldAddr, address newAddr) external onlyAdmin {

        require(oldAddr != address(0) && newAddr != address(0), "REPLACE: ZERO ADDRESS");

        require(invStats[oldAddr], "REPLACE: OLD NOT BINDED");

        require(!invStats[newAddr], "REPLACE: NEW ALREADY BINDED");

        address parent = Inviter[oldAddr];
        require(parent != address(0), "REPLACE: OLD NO PARENT");

        address[] storage parentChildren = invList[parent];
        bool replaced = false;
        for (uint256 i = 0; i < parentChildren.length; i++) {
            if (parentChildren[i] == oldAddr) {
                parentChildren[i] = newAddr;
                replaced = true;
                break;
            }
        }
        require(replaced, "REPLACE: OLD NOT FOUND IN PARENT");

        Inviter[newAddr] = parent;
        invStats[newAddr] = true;
        level[newAddr] = level[oldAddr];

        address[] storage children = invList[oldAddr];
        for (uint256 i = 0; i < children.length; i++) {
            address child = children[i];

            Inviter[child] = newAddr;

            invList[newAddr].push(child);
        }

        delete invList[oldAddr];

        invStats[oldAddr] = false;
        Inviter[oldAddr] = address(0);
        level[oldAddr] = 0;

        emit ReplaceBind(oldAddr, newAddr);
    }

    function bind(address inv)
    external
    {
        require(!invStats[msg.sender], "BIND ERROR: ONCE BIND");
        require(invStats[inv], "BIND ERROR: INVITER NOT BIND YET");
        _bind(msg.sender, inv);

    }

    function mintBind(address child, address parent)
    external onlyAdmin
    {
        require(!invStats[child], "BIND ERROR: ONCE BIND");
        require(invStats[parent], "BIND ERROR: INVITER NOT BIND YET");

        _bind(child, parent);
    }

    function _bind(address child, address parent)
    internal
    {

        Inviter[child] = parent;
        invList[parent].push(child);
        invStats[child] = true;

        if(level[parent] > 0){
            level[child] = level[parent].add(1);
        }

        emit Bind(parent, child, level[child]);
    }

    function BatchBind(address[] memory childs, address[] memory parents)
        external
        onlyAdmin
    {
        require(childs.length == parents.length, "BATCH BIND: arrays length mismatch");
        for (uint256 i = 0; i < childs.length; i++) {
            address child = childs[i];
            address parent = parents[i];
            require(!invStats[child], "BIND ERROR: ONCE BIND");
            require(invStats[parent], "BIND ERROR: INVITER NOT BIND YET");
            _bind(child, parent);
        }
    }

    function invListLength(address addr_) public view returns (uint256) {
        return invList[addr_].length;
    }

    function getInvList(address addr_)
        public
        view
        returns (address[] memory _addrsList)
    {
        _addrsList = new address[](invList[addr_].length);
        for (uint256 i = 0; i < invList[addr_].length; i++) {
            _addrsList[i] = invList[addr_][i];
        }
    }

    function batchBindByParent(address parent, address[] memory addrs) external onlyAdmin{
        require(invStats[parent], "BIND ERROR: INVITER NOT BIND YET");
        for (uint256 i = 0; i < addrs.length; i++) {
            if(!invStats[addrs[i]]){
                _bind(addrs[i], parent);
            }

        }
    }

    function batchAddrBindStatus(address[] memory addrs) external view returns(bool[] memory){
        bool[] memory bindstatus = new bool[](addrs.length);

        for (uint256 index = 0; index < addrs.length; index++) {
            bindstatus[index] = invStats[addrs[index]];
        }

        return bindstatus;
    }

    function batchBindWithParentAndChild(address[] memory childs, address[] memory parents) external onlyAdmin{
        for (uint256 index = 0; index < childs.length; index++) {
            if(!invStats[childs[index]]){
                _bind(childs[index], parents[index]);
            }
        }
    }

    function rebindRelation(address child, address newParent) external onlyAdmin {
        require(invStats[child], "REBIND: child not bound");
        require(invStats[newParent], "REBIND: newParent not bound");
        require(child != newParent, "REBIND: self binding prohibited");

        address oldParent = Inviter[child];
        require(oldParent != address(0), "REBIND: oldParent not found");

        address[] storage oldChildren = invList[oldParent];
        bool found = false;
        for (uint256 i = 0; i < oldChildren.length; i++) {
            if (oldChildren[i] == child) {
                oldChildren[i] = oldChildren[oldChildren.length - 1];
                oldChildren.pop();
                found = true;
                break;
            }
        }
        require(found, "REBIND: child not found in oldParent's list");

        Inviter[child] = newParent;
        invList[newParent].push(child);

        uint256 oldLevel = level[child];
        uint256 newLevel = level[newParent].add(1);

        _updateLevelsRecursively(child, oldLevel, newLevel);

    }

    function _updateLevelsRecursively(address user, uint256 oldL, uint256 newL) internal {
        level[user] = newL;

        address[] storage children = invList[user];
        for (uint256 i = 0; i < children.length; i++) {
            address targetChild = children[i];
            uint256 childOldLevel = level[targetChild];

            uint256 childNewLevel;
            if (newL > oldL) {
                childNewLevel = childOldLevel.add(newL.sub(oldL));
            } else {
                childNewLevel = childOldLevel.sub(oldL.sub(newL));
            }

            _updateLevelsRecursively(targetChild, childOldLevel, childNewLevel);
        }
    }
}
