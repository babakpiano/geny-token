// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

/// @title GenyUUPSProxy
/// @author compez.eth
/// @notice A UUPS proxy contract for the Genyleap ecosystem, following the ERC1967 standard.
/// @dev Delegates calls to an implementation contract and allows upgrades by the admin (typically a multisig like Gnosis Safe).
///      Supports upgradeTo and upgradeToAndCall for flexible upgrades. Stores implementation and admin addresses in ERC1967 slots.
///      Emits standard ERC1967 events (Upgraded, AdminChanged) for tracking changes. Allows receiving ETH for implementations that need it.
/// @custom:security-contact security@genyleap.com
contract GenyUUPSProxy {
    // --- ERC1967 storage slots ---
    /// @dev Slot for the implementation address
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev Slot for the admin address
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Emitted when the implementation is upgraded
    /// @param implementation Address of the new implementation
    event Upgraded(address indexed implementation);

    /// @notice Emitted when the admin is changed
    /// @param previousAdmin Address of the previous admin
    /// @param newAdmin Address of the new admin
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    /// @dev Custom error for invalid addresses
    error InvalidAddress();
    /// @dev Custom error for non-contract addresses
    error NotContract();
    /// @dev Custom error for unauthorized access
    error Unauthorized();
    /// @dev Custom error for failed initialization or call
    error CallFailed();

    /// @notice Initializes the proxy with an implementation, admin, and optional initialization data
    /// @dev Sets the implementation and admin addresses in ERC1967 slots. Optionally calls the implementation with initialization data.
    ///      Reverts if the implementation or admin is invalid or if initialization fails.
    /// @param implementation Address of the initial implementation contract
    /// @param admin Address of the admin (e.g., a multisig like Gnosis Safe)
    /// @param data Initialization data to call on the implementation
    constructor(address implementation, address admin, bytes memory data) payable {
        if (implementation == address(0) || admin == address(0)) revert InvalidAddress();
        if (!_isContract(implementation)) revert NotContract();

        _setImplementation(implementation);
        _setAdmin(admin);

        if (data.length > 0) {
            (bool success, ) = implementation.delegatecall(data);
            if (!success) revert CallFailed();
        }
    }

    /// @notice Upgrades the proxy to a new implementation
    /// @dev Only callable by the admin. Reverts if the new implementation is invalid or not a contract.
    /// @param newImplementation Address of the new implementation contract
    function upgradeTo(address newImplementation) external {
        if (msg.sender != _getAdmin()) revert Unauthorized();
        if (newImplementation == address(0)) revert InvalidAddress();
        if (!_isContract(newImplementation)) revert NotContract();

        _setImplementation(newImplementation);
    }

    /// @notice Upgrades the proxy and calls a function on the new implementation
    /// @dev Only callable by the admin. Supports payable calls for implementations that require ETH.
    ///      Reverts if the new implementation is invalid or if the call fails.
    /// @param newImplementation Address of the new implementation contract
    /// @param data Calldata to send to the new implementation
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable {
        if (msg.sender != _getAdmin()) revert Unauthorized();
        if (newImplementation == address(0)) revert InvalidAddress();
        if (!_isContract(newImplementation)) revert NotContract();

        _setImplementation(newImplementation);
        if (data.length > 0) {
            (bool success, ) = newImplementation.delegatecall(data);
            if (!success) revert CallFailed();
        }
    }

    /// @notice Changes the admin of the proxy
    /// @dev Only callable by the current admin. Reverts if the new admin is invalid.
    /// @param newAdmin Address of the new admin
    function changeAdmin(address newAdmin) external {
        if (msg.sender != _getAdmin()) revert Unauthorized();
        if (newAdmin == address(0)) revert InvalidAddress();
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

    /// @dev Delegates all calls to the implementation contract
    /// @notice Handles all function calls by delegating to the implementation
    fallback() external payable {
        address impl = _getImplementation();
        if (impl == address(0)) revert InvalidAddress();

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @dev Allows the proxy to receive ETH (e.g., for implementations like GenyTreasury)
    receive() external payable {}

    // --- Internal/private: Slot handling and helpers ---

    /// @dev Sets the implementation address in the ERC1967 slot
    /// @param newImplementation Address of the new implementation
    function _setImplementation(address newImplementation) private {
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        emit Upgraded(newImplementation);
    }

    /// @dev Gets the implementation address from the ERC1967 slot
    /// @return impl The address of the implementation
    function _getImplementation() private view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    /// @dev Sets the admin address in the ERC1967 slot
    /// @param newAdmin Address of the new admin
    function _setAdmin(address newAdmin) private {
        address oldAdmin = _getAdmin();
        assembly {
            sstore(_ADMIN_SLOT, newAdmin)
        }
        emit AdminChanged(oldAdmin, newAdmin);
    }

    /// @dev Gets the admin address from the ERC1967 slot
    /// @return admin The address of the admin
    function _getAdmin() private view returns (address admin) {
        assembly {
            admin := sload(_ADMIN_SLOT)
        }
    }

    /// @dev Checks if an address is a contract
    /// @param addr Address to check
    /// @return True if the address is a contract
    function _isContract(address addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
