// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

/**
 * @title GenyGuard
 * @author compez.eth
 * @notice Modular, non-custodial recovery protection for any EVM address with irreversible recovery key and a one-time grace period for correction.
 * @custom:security-contact security@genyleap.com
 */
contract GenyGuard {
    /// @dev Stores user's recovery wallet address
    mapping(address => address) private _recoveryWallet;

    /// @dev Indicates if recovery mode is activated
    mapping(address => bool) private _recoveryModeActivated;

    /// @dev Flags if user is marked as compromised (analytics)
    mapping(address => bool) private _isCompromised;

    /// @dev Stores salted hash of recovery key per user
    mapping(address => bytes32) private _recoveryKeyHash;

    /// @dev Unique salt for each user
    mapping(address => bytes32) private _userSalt;

    /// @dev Timestamp when recovery key was first set
    mapping(address => uint256) private _recoveryKeySetTime;

    /// @dev Has user changed their recovery key once in grace period?
    mapping(address => bool) private _hasChangedRecoveryKey;

    /// @notice Grace period (24 hours) for a one-time recovery key correction
    uint256 public constant RECOVERY_KEY_GRACE_PERIOD = 24 hours;

    // --- Events ---

    /// @notice Emitted when a user's salt is generated
    event UserSaltGenerated(address indexed user, bytes32 salt);

    /// @notice Emitted when the recovery key hash is set
    event RecoveryKeySet(address indexed user, bytes32 hash, bytes32 salt, uint256 timestamp);

    /// @notice Emitted when recovery key is changed in grace period
    event RecoveryKeyChanged(address indexed user, bytes32 newHash, uint256 timestamp);

    /// @notice Emitted when recovery wallet is set or changed
    event RecoveryWalletSet(address indexed user, address indexed recoveryWallet);

    /// @notice Emitted when recovery mode is activated
    event RecoveryModeActivated(address indexed user);

    /// @notice Emitted when recovery mode is deactivated
    event RecoveryModeDeactivated(address indexed user);

    /// @notice Emitted when account is marked as compromised
    event AddressCompromised(address indexed user);

    // --- Errors ---
    error SaltAlreadyGenerated();
    error SaltNotGenerated();
    error RecoveryKeyAlreadySet();
    error RecoveryKeyNotSet();
    error GracePeriodExpired();
    error RecoveryKeyAlreadyChanged();
    error InvalidRecoveryKey();
    error ZeroAddress();
    error NotInRecoveryMode();

    // --- Core Logic ---

    /**
     * @notice Generates and stores a unique salt for the sender. Only once per user.
     * @dev Should be called before setting a recovery key.
     * @return salt The newly generated salt.
     */
    function generateSalt() external returns (bytes32 salt) {
        if (_userSalt[msg.sender] != bytes32(0)) revert SaltAlreadyGenerated();
        salt = keccak256(abi.encodePacked(msg.sender, block.timestamp, block.prevrandao));
        _userSalt[msg.sender] = salt;
        emit UserSaltGenerated(msg.sender, salt);
    }

    /**
     * @notice Sets the salted hash of the recovery key (keccak256(key || salt)), one-time with grace period for correction.
     * @param hash Salted keccak256 hash of recovery key (client: keccak256(key || salt))
     */
    function setRecoveryKey(bytes32 hash) external {
        if (_recoveryKeyHash[msg.sender] != bytes32(0)) revert RecoveryKeyAlreadySet();
        if (_userSalt[msg.sender] == bytes32(0)) revert SaltNotGenerated();
        _recoveryKeyHash[msg.sender] = hash;
        _recoveryKeySetTime[msg.sender] = block.timestamp;
        emit RecoveryKeySet(msg.sender, hash, _userSalt[msg.sender], block.timestamp);
    }

    /**
     * @notice Allows a one-time correction of recovery key within grace period (24h).
     * @param newHash The new salted hash of recovery key.
     */
    function changeRecoveryKey(bytes32 newHash) external {
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        if (_hasChangedRecoveryKey[msg.sender]) revert RecoveryKeyAlreadyChanged();
        if (block.timestamp > _recoveryKeySetTime[msg.sender] + RECOVERY_KEY_GRACE_PERIOD) revert GracePeriodExpired();
        _recoveryKeyHash[msg.sender] = newHash;
        _hasChangedRecoveryKey[msg.sender] = true;
        emit RecoveryKeyChanged(msg.sender, newHash, block.timestamp);
    }

    /**
     * @notice Sets or changes the recovery wallet, requires correct recovery key.
     * @param recoveryWallet The address to set as recovery wallet.
     * @param recoveryKey The user's recovery key (checked as keccak256(key || salt)).
     */
    function setRecoveryWallet(address recoveryWallet, string calldata recoveryKey) external {
        if (recoveryWallet == address(0)) revert ZeroAddress();
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        bytes32 salt = _userSalt[msg.sender];
        if (salt == bytes32(0)) revert SaltNotGenerated();
        bytes32 checkHash = keccak256(abi.encodePacked(recoveryKey, salt));
        if (checkHash != _recoveryKeyHash[msg.sender]) revert InvalidRecoveryKey();
        _recoveryWallet[msg.sender] = recoveryWallet;
        emit RecoveryWalletSet(msg.sender, recoveryWallet);
    }

    /**
     * @notice Activates recovery mode for the user, requires valid recovery key.
     * @param recoveryKey The recovery key to authorize activation.
     */
    function activateRecoveryMode(string calldata recoveryKey) external {
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        bytes32 checkHash = keccak256(abi.encodePacked(recoveryKey, _userSalt[msg.sender]));
        if (checkHash != _recoveryKeyHash[msg.sender]) revert InvalidRecoveryKey();
        _recoveryModeActivated[msg.sender] = true;
        emit RecoveryModeActivated(msg.sender);
    }

    /**
     * @notice Deactivates recovery mode, requires valid recovery key.
     * @param recoveryKey The recovery key to authorize deactivation.
     */
    function deactivateRecoveryMode(string calldata recoveryKey) external {
        if (!_recoveryModeActivated[msg.sender]) revert NotInRecoveryMode();
        bytes32 checkHash = keccak256(abi.encodePacked(recoveryKey, _userSalt[msg.sender]));
        if (checkHash != _recoveryKeyHash[msg.sender]) revert InvalidRecoveryKey();
        _recoveryModeActivated[msg.sender] = false;
        emit RecoveryModeDeactivated(msg.sender);
    }

    /**
     * @notice Marks the user's account as compromised, requires valid recovery key.
     * @param recoveryKey The recovery key to authorize marking compromised.
     */
    function markCompromised(string calldata recoveryKey) external {
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        bytes32 checkHash = keccak256(abi.encodePacked(recoveryKey, _userSalt[msg.sender]));
        if (checkHash != _recoveryKeyHash[msg.sender]) revert InvalidRecoveryKey();
        _isCompromised[msg.sender] = true;
        emit AddressCompromised(msg.sender);
    }

    // --- Getters ---

    function getRecoveryWallet(address user) external view returns (address) {
        return _recoveryWallet[user];
    }

    function getUserSalt(address user) external view returns (bytes32) {
        return _userSalt[user];
    }

    function isInGracePeriod(address user) external view returns (bool) {
        if (_recoveryKeySetTime[user] == 0) return false;
        return block.timestamp <= _recoveryKeySetTime[user] + RECOVERY_KEY_GRACE_PERIOD &&
               !_hasChangedRecoveryKey[user];
    }

    function isRecoveryModeActive(address user) external view returns (bool) {
        return _recoveryModeActivated[user];
    }

    function isCompromised(address user) external view returns (bool) {
        return _isCompromised[user];
    }
}
