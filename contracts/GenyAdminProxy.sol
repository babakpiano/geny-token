// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

/// @title GenyAdminProxy (ERC1967)
/// @author compez.eth
/// @notice Admin-controlled upgradeable proxy for the Genyleap ecosystem.
/// @dev Delegates all calls to the implementation stored in the ERC1967 slot.
/// Upgrades are performed by the proxy admin (e.g., a Gnosis Safe) via {upgradeTo}
/// and {upgradeToAndCall}. This proxy emits standard ERC1967 events {Upgraded}
/// and {AdminChanged}, and can receive ETH for implementations that need it.
///
/// Safety checks:
/// - If the current implementation exposes `upgradesDisabled()` and it returns true,
///   upgrades are blocked (checked via delegatecall before upgrading).
/// - If `strictUUPSCheck` is enabled, the new implementation must implement
///   `proxiableUUID()` and match the ERC1967 implementation slot (UUPS sanity check).
///
/// NOTE: This is an admin proxy. Implementation-level `_authorizeUpgrade` guards
/// (typical UUPS) are not enforced here; the proxy admin is the upgrade authority.
///
/// @custom:security-contact security@genyleap.com
contract GenyAdminProxy {
    // --- ERC1967 storage slots ---
    /// @dev EIP-1967 implementation slot.
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev EIP-1967 admin slot.
    bytes32 private constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // --- Events ---
    event Upgraded(address indexed implementation);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event StrictUUPSCheckSet(bool enabled);

    // --- Errors ---
    error InvalidAddress();
    error NotContract();
    error Unauthorized();
    error CallFailed();
    error UpgradesDisabledError();
    error SameImplementation();
    error NotUUPSCompatible();

    /// @notice Optional guard to require new implementations to expose UUPS proxiableUUID().
    bool public strictUUPSCheck;

    /// @notice Deploys the proxy with implementation, admin, and optional init call.
    /// @param implementation Initial implementation.
    /// @param admin Initial admin (e.g., multisig).
    /// @param data Optional initialization calldata (delegatecalled into implementation).
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

    // --- Admin-only ops ---

    /// @notice Upgrades to a new implementation.
    function upgradeTo(address newImplementation) external onlyAdmin {
        _preUpgradeChecks(newImplementation);
        _setImplementation(newImplementation);
    }

    /// @notice Upgrades to a new implementation and calls a function on it.
    function upgradeToAndCall(address newImplementation, bytes memory data) external payable onlyAdmin {
        _preUpgradeChecks(newImplementation);
        _setImplementation(newImplementation);
        if (data.length > 0) {
            (bool callSuccess, ) = newImplementation.delegatecall(data);
            if (!callSuccess) revert CallFailed();
        }
    }

    /// @notice Changes the proxy admin.
    function changeAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert InvalidAddress();
        _setAdmin(newAdmin);
    }

    /// @notice Enables/disables strict UUPS proxiableUUID() check on upgrades.
    function setStrictUUPSCheck(bool enabled) external onlyAdmin {
        strictUUPSCheck = enabled;
        emit StrictUUPSCheckSet(enabled);
    }

    // --- Views ---

    /// @notice Returns current implementation address.
    function getImplementation() external view returns (address impl) {
        impl = _getImplementation();
    }

    /// @notice Returns current admin address.
    function getAdmin() external view returns (address admin) {
        admin = _getAdmin();
    }

    // --- Fallback / Receive ---

    /// @dev Delegates all unknown calls to the implementation.
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

    /// @dev Allow receiving ETH.
    receive() external payable {}

    // --- Internal logic ---

    function _preUpgradeChecks(address newImplementation) internal {
        if (newImplementation == address(0)) revert InvalidAddress();
        if (!_isContract(newImplementation)) revert NotContract();
        address current = _getImplementation();
        if (newImplementation == current) revert SameImplementation();

        // If the current implementation exposes upgradesDisabled() and returns true, block upgrade.
        (bool ok, bytes memory ret) =
            address(this).delegatecall(abi.encodeWithSignature("upgradesDisabled()"));
        if (ok && ret.length >= 32 && abi.decode(ret, (bool))) {
            revert UpgradesDisabledError();
        }

        // Optional UUPS sanity check on the *new* implementation (proxiableUUID()).
        if (strictUUPSCheck) {
            (bool s, bytes memory out) =
                newImplementation.staticcall(abi.encodeWithSignature("proxiableUUID()"));
            if (!(s && out.length == 32 && bytes32(out) == _IMPLEMENTATION_SLOT)) {
                revert NotUUPSCompatible();
            }
        }
    }

    function _setImplementation(address newImplementation) private {
        assembly { sstore(_IMPLEMENTATION_SLOT, newImplementation) }
        emit Upgraded(newImplementation);
    }

    function _getImplementation() private view returns (address impl) {
        assembly { impl := sload(_IMPLEMENTATION_SLOT) }
    }

    function _setAdmin(address newAdmin) private {
        address oldAdmin = _getAdmin();
        assembly { sstore(_ADMIN_SLOT, newAdmin) }
        emit AdminChanged(oldAdmin, newAdmin);
    }

    function _getAdmin() private view returns (address admin) {
        assembly { admin := sload(_ADMIN_SLOT) }
    }

    function _isContract(address a) private view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(a) }
        return size > 0;
    }

    // --- Modifier ---

    modifier onlyAdmin() {
        if (msg.sender != _getAdmin()) revert Unauthorized();
        _;
    }
}
