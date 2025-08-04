// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap
pragma solidity 0.8.30;

/// @title GenyUUPSProxy
/// @author compez.eth
/// @notice A UUPS proxy contract for the Genyleap ecosystem, following the ERC1967 standard.
/// @dev Delegates calls to an implementation contract and allows upgrades by the admin (typically a multisig like Gnosis Safe).
/// Supports upgradeTo and upgradeToAndCall for flexible upgrades. Stores implementation and admin addresses in ERC1967 slots.
/// Emits standard ERC1967 events (Upgraded, AdminChanged) for tracking changes. Allows receiving ETH for implementations that need it.
/// @custom:security-contact security@genyleap.com
contract GenyUUPSProxy {
    // --- ERC1967 storage slots ---
    /// @dev Storage slot for the implementation address, as defined in ERC1967.
    bytes32 private constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev Storage slot for the admin address, as defined in ERC1967.
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @dev Event emitted when the implementation is upgraded.
    event Upgraded(address indexed implementation);
    /// @dev Event emitted when the admin is changed.
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);

    /// @dev Error thrown when an invalid address (zero address) is provided.
    error InvalidAddress();
    /// @dev Error thrown when the provided address is not a contract.
    error NotContract();
    /// @dev Error thrown when the caller is not authorized (not the admin).
    error Unauthorized();
    /// @dev Error thrown when a delegatecall fails.
    error CallFailed();
    /// @dev Error thrown when upgrades are disabled in the implementation.
    error UpgradesDisabledError();

    /// @notice Constructor to initialize the proxy with an implementation, admin, and optional initialization data.
    /// @param implementation The address of the initial implementation contract.
    /// @param admin The address of the initial admin (e.g., a multisig).
    /// @param data Optional calldata to initialize the implementation via delegatecall.
    /// @dev Reverts if implementation or admin is zero address or if implementation is not a contract.
    ///      Executes the initialization data if provided and reverts on failure.
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

    /// @notice Upgrades the proxy to a new implementation.
    /// @param newImplementation The address of the new implementation contract.
    /// @dev Only callable by the admin. Checks if upgrades are disabled via delegatecall to the current implementation.
    ///      Reverts if not authorized, invalid address, not a contract, or upgrades disabled.
    function upgradeTo(address newImplementation) external {
        if (msg.sender != _getAdmin()) revert Unauthorized();
        if (newImplementation == address(0)) revert InvalidAddress();
        if (!_isContract(newImplementation)) revert NotContract();
        // delegatecall to self, to read upgradesDisabled state from proxy's storage
        (bool success, bytes memory result) = address(this).delegatecall(abi.encodeWithSignature("upgradesDisabled()"));
        if (success && result.length > 0 && abi.decode(result, (bool))) revert UpgradesDisabledError();
        _setImplementation(newImplementation);
    }

    /// @notice Upgrades the proxy to a new implementation and calls a function on it.
    /// @param newImplementation The address of the new implementation contract.
    /// @param data Calldata to execute on the new implementation via delegatecall.
    /// @dev Only callable by the admin. Allows value transfer (payable). Checks if upgrades are disabled.
    ///      Reverts on failures similar to upgradeTo, plus on delegatecall failure if data is provided.
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable {
        if (msg.sender != _getAdmin()) revert Unauthorized();
        if (newImplementation == address(0)) revert InvalidAddress();
        if (!_isContract(newImplementation)) revert NotContract();
        (bool success, bytes memory result) = address(this).delegatecall(abi.encodeWithSignature("upgradesDisabled()"));
        if (success && result.length > 0 && abi.decode(result, (bool))) revert UpgradesDisabledError();
        _setImplementation(newImplementation);
        if (data.length > 0) {
            (bool callSuccess, ) = newImplementation.delegatecall(data);
            if (!callSuccess) revert CallFailed();
        }
    }

    /// @notice Changes the admin of the proxy.
    /// @param newAdmin The address of the new admin.
    /// @dev Only callable by the current admin. Reverts if not authorized or newAdmin is zero address.
    function changeAdmin(address newAdmin) external {
        if (msg.sender != _getAdmin()) revert Unauthorized();
        if (newAdmin == address(0)) revert InvalidAddress();
        _setAdmin(newAdmin);
    }

    /// @notice Retrieves the current implementation address.
    /// @return impl The address of the current implementation.
    function getImplementation() external view returns (address impl) {
        impl = _getImplementation();
    }

    /// @notice Retrieves the current admin address.
    /// @return admin The address of the current admin.
    function getAdmin() external view returns (address admin) {
        admin = _getAdmin();
    }

    /// @dev Fallback function to delegate calls to the implementation.
    ///      Reverts if no implementation is set.
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

    /// @dev Receive function to allow the proxy to receive ETH.
    receive() external payable {}

    /// @dev Internal function to set the implementation address in storage.
    /// @param newImplementation The new implementation address.
    ///      Emits the Upgraded event.
    function _setImplementation(address newImplementation) private {
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }
        emit Upgraded(newImplementation);
    }

    /// @dev Internal function to get the implementation address from storage.
    /// @return impl The implementation address.
    function _getImplementation() private view returns (address impl) {
        assembly {
            impl := sload(_IMPLEMENTATION_SLOT)
        }
    }

    /// @dev Internal function to set the admin address in storage.
    /// @param newAdmin The new admin address.
    ///      Emits the AdminChanged event.
    function _setAdmin(address newAdmin) private {
        address oldAdmin = _getAdmin();
        assembly {
            sstore(_ADMIN_SLOT, newAdmin)
        }
        emit AdminChanged(oldAdmin, newAdmin);
    }

    /// @dev Internal function to get the admin address from storage.
    /// @return admin The admin address.
    function _getAdmin() private view returns (address admin) {
        assembly {
            admin := sload(_ADMIN_SLOT)
        }
    }

    /// @dev Internal function to check if an address is a contract.
    /// @param addr The address to check.
    /// @return True if the address has code (is a contract), false otherwise.
    function _isContract(address addr) private view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}