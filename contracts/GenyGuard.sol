// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title GenyGuard
/// @author compez.eth
/// @notice Modular, non-custodial recovery protection for any EVM address with irreversible, Apple-style recovery key logic.
/// @custom:security-contact security@genyleap.com
contract GenyGuard {
    /// @dev Stores user's recovery wallet
    mapping(address => address) private _recoveryWallet;
    /// @dev True if recovery mode is activated
    mapping(address => bool) private _recoveryModeActivated;
    /// @dev True if user marked as compromised (for analytics)
    mapping(address => bool) private _isCompromised;
    /// @dev One-time, irreversible code hash (Apple-style Recovery Key, non-changeable)
    mapping(address => bytes32) private _recoveryKeyHash;

    /// === Events ===
    event RecoveryWalletSet(address indexed user, address indexed recoveryWallet);
    event RecoveryModeActivated(address indexed user);
    event RecoveryModeDeactivated(address indexed user);
    event AddressCompromised(address indexed compromisedWallet);
    event RecoveryKeySet(address indexed user, bytes32 indexed recoveryKeyHash);

    /// === Errors ===
    error InvalidCode();
    error RecoveryWalletAlreadySet();
    error RecoveryKeyAlreadySet();
    error RecoveryKeyNotSet();
    error Unauthorized();

    // ====== USER FLOW ======
    /// @notice User sets their recovery key (Apple-style, only once and forever)
    /// @param recoveryKeyHash Hash of their chosen recovery key (must be Apple-like: keccak256 of a code in form XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX)
    function setRecoveryKey(bytes32 recoveryKeyHash) external {
        if (_recoveryKeyHash[msg.sender] != bytes32(0)) revert RecoveryKeyAlreadySet();
        _recoveryKeyHash[msg.sender] = recoveryKeyHash;
        emit RecoveryKeySet(msg.sender, recoveryKeyHash);
    }

    /// @notice Set recovery wallet, must provide correct recovery code
    /// @param wallet New recovery wallet address
    /// @param code Apple-style recovery code (plain text, e.g. 'ABCD-EFGH-IJKL-MNOP-QRST-UVWX-YZ12')
    function setRecoveryWallet(address wallet, string calldata code) external {
        if (wallet == address(0)) revert InvalidCode();
        if (_recoveryWallet[msg.sender] != address(0)) revert RecoveryWalletAlreadySet();
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();

        // Validate code
        if (keccak256(abi.encodePacked(code)) != _recoveryKeyHash[msg.sender]) revert InvalidCode();
        _recoveryWallet[msg.sender] = wallet;
        emit RecoveryWalletSet(msg.sender, wallet);
    }

    /// @notice (Irreversible) Activate recovery mode (must have recovery wallet & recovery key)
    /// @param code Apple-style recovery code for auth
    function activateRecoveryMode(string calldata code) external {
        if (_recoveryWallet[msg.sender] == address(0)) revert InvalidCode();
        if (_recoveryModeActivated[msg.sender]) revert RecoveryWalletAlreadySet();
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();

        if (keccak256(abi.encodePacked(code)) != _recoveryKeyHash[msg.sender]) revert InvalidCode();

        _recoveryModeActivated[msg.sender] = true;
        _isCompromised[msg.sender] = true;
        emit RecoveryModeActivated(msg.sender);
        emit AddressCompromised(msg.sender);
    }

    /// @notice Change the recovery wallet at any time, only with the correct recovery key.
    /// @param newWallet The new recovery wallet address
    /// @param code The original Apple-style recovery key
    function changeRecoveryWallet(address newWallet, string calldata code) external {
        if (newWallet == address(0)) revert InvalidCode();
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        if (keccak256(abi.encodePacked(code)) != _recoveryKeyHash[msg.sender]) revert InvalidCode();

        _recoveryWallet[msg.sender] = newWallet;
        emit RecoveryWalletSet(msg.sender, newWallet);
    }

    /// @notice Deactivate recovery mode (and optionally remove recovery wallet), only by correct recovery key
    /// @param code The original Apple-style recovery key
    function deactivateRecoveryMode(string calldata code) external {
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        if (keccak256(abi.encodePacked(code)) != _recoveryKeyHash[msg.sender]) revert InvalidCode();
        if (!_recoveryModeActivated[msg.sender]) revert("Not in recovery mode");
        _recoveryModeActivated[msg.sender] = false;
        emit RecoveryModeDeactivated(msg.sender);
    }

    // ====== VIEW FUNCTIONS ======

    /// @notice Get registered recovery wallet for a user
    function getRecoveryWallet(address user) external view returns (address) {
        return _recoveryWallet[user];
    }

    /// @notice Is user in recovery mode?
    function isRecoveryModeActive(address user) external view returns (bool) {
        return _recoveryModeActivated[user];
    }

    /// @notice Has user marked address as compromised?
    function isCompromised(address user) external view returns (bool) {
        return _isCompromised[user];
    }

    /// @notice Get recovery key hash (for dApps, only returns hash)
    function getRecoveryKeyHash(address user) external view returns (bytes32) {
        return _recoveryKeyHash[user];
    }
}
