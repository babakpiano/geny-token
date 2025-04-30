// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

/// @title GenyUUPSProxy
/// @author compez.eth
/// @notice A UUPS proxy contract for the Genyleap ecosystem, based on ERC1967 standard.
/// @dev Delegates calls to an implementation contract and allows upgrades by the admin.
/// @custom:security-contact security@genyleap.com
contract GenyUUPSProxy {
    // Storage slots as per ERC1967 standard
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Emitted when the implementation is upgraded
    /// @param implementation Address of the new implementation
    event Upgraded(address indexed implementation);
    /// @notice Emitted when the admin is changed
    /// @param previousAdmin Address of the previous admin
    /// @param newAdmin Address of the new admin
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    /// @notice Initializes the proxy with an implementation and admin
    /// @param _implementation Address of the initial implementation contract
    /// @param _admin Address of the admin who can upgrade the proxy
    /// @param _data Initialization data to call on the implementation
    constructor(address _implementation, address _admin, bytes memory _data) payable {
        require(_implementation != address(0) && _admin != address(0), "Invalid address");
        require(isContract(_implementation), "Implementation is not a contract");

        _setImplementation(_implementation);
        _setAdmin(_admin);

        if (_data.length > 0) {
            (bool success, ) = _implementation.delegatecall(_data);
            require(success, "Initialization failed");
        }
    }

    /// @notice Upgrades the proxy to a new implementation
    /// @param newImplementation Address of the new implementation contract
    function upgradeTo(address newImplementation) external {
        require(msg.sender == _getAdmin(), "Caller is not admin");
        require(newImplementation != address(0) && isContract(newImplementation), "Invalid implementation");

        _setImplementation(newImplementation);
    }

    /// @notice Upgrades the proxy and calls a function on the new implementation
    /// @param newImplementation Address of the new implementation contract
    /// @param data Calldata to send to the new implementation
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable {
        require(msg.sender == _getAdmin(), "Caller is not admin");
        require(newImplementation != address(0) && isContract(newImplementation), "Invalid implementation");

        _setImplementation(newImplementation);
        if (data.length > 0) {
            (bool success, ) = newImplementation.delegatecall(data);
            require(success, "Call failed");
        }
    }

    /// @notice Changes the admin of the proxy
    /// @param newAdmin Address of the new admin
    function changeAdmin(address newAdmin) external {
        require(msg.sender == _getAdmin(), "Caller is not admin");
        require(newAdmin != address(0), "Invalid admin");
        _setAdmin(newAdmin);
    }

    /// @notice Returns the current implementation address
    /// @return impl The address of the implementation contract
    function getImplementation() external view returns (address impl) {
        impl = _getImplementation();
    }

    /// @notice Returns the current admin address
    /// @return admin The address of the proxy admin
    function getAdmin() external view returns (address admin) {
        admin = _getAdmin();
    }

    /// @dev Delegates calls to the implementation
    fallback() external payable {
        address impl = _getImplementation();
        require(impl != address(0), "Implementation not set");

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @dev Allows receiving Ether
    receive() external payable {}

    /// @dev Sets the implementation address
    function _setImplementation(address newImplementation) private {
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        emit Upgraded(newImplementation);
    }

    /// @dev Gets the implementation address
    function _getImplementation() private view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    /// @dev Sets the admin address
    function _setAdmin(address newAdmin) private {
        address oldAdmin = _getAdmin();
        assembly {
            sstore(_ADMIN_SLOT, newAdmin)
        }
        emit AdminChanged(oldAdmin, newAdmin);
    }

    /// @dev Gets the admin address
    function _getAdmin() private view returns (address admin) {
        assembly {
            admin := sload(_ADMIN_SLOT)
        }
    }

    /// @dev Checks if an address is a contract
    function isContract(address addr) private view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }
}