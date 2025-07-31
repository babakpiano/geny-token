// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

/**
 * @title GenyGuard
 * @author compez.eth
 * @notice Modular, non-custodial recovery protection for any EVM address using irreversible rotating recovery hashes.
 * @dev All sensitive actions require hash rotation for replay protection. No sensitive key is ever sent onchain.
 * @custom:security-contact security@genyleap.com
 */
contract GenyGuard {
    /// @notice Stores recovery wallet address per user
    mapping(address => address) private _recoveryWallet;

    /// @notice Stores salted hash of recovery key per user (must rotate after every action)
    mapping(address => bytes32) private _recoveryKeyHash;

    /// @notice Unique salt for each user (visible, but safe if key is strong)
    mapping(address => bytes32) private _userSalt;

    /// @notice Indicates if recovery mode is active
    mapping(address => bool) private _recoveryModeActivated;

    /// @notice Flags if user is marked as compromised (for analytics/monitoring)
    mapping(address => bool) private _isCompromised;

    /// @notice Timestamp when recovery key was set (for optional time-based features)
    mapping(address => uint256) private _recoveryKeySetTime;

    /// @notice Emitted when a user's salt is generated
    event UserSaltGenerated(address indexed user, bytes32 salt);

    /// @notice Emitted when recovery key hash is rotated
    event RecoveryKeyRotated(address indexed user, bytes32 newHash, uint256 timestamp);

    /// @notice Emitted when recovery wallet is set/changed
    event RecoveryWalletSet(address indexed user, address indexed recoveryWallet);

    /// @notice Emitted when recovery mode is activated
    event RecoveryModeActivated(address indexed user);

    /// @notice Emitted when recovery mode is deactivated
    event RecoveryModeDeactivated(address indexed user);

    /// @notice Emitted when user is marked as compromised
    event AddressCompromised(address indexed user);

    // --- Errors ---
    error SaltAlreadyGenerated();
    error SaltNotGenerated();
    error RecoveryKeyNotSet();
    error InvalidRecoveryHash();
    error ZeroAddress();
    error NotInRecoveryMode();

    // --- Core Logic ---

    /**
     * @notice Generates and stores a unique salt for the sender. Only once per user.
     * @dev Should be called before setting a recovery key for the first time.
     * @return salt The newly generated salt.
     */
    function generateSalt() external returns (bytes32 salt) {
        if (_userSalt[msg.sender] != bytes32(0)) revert SaltAlreadyGenerated();
        salt = keccak256(abi.encodePacked(msg.sender, block.timestamp, block.prevrandao));
        _userSalt[msg.sender] = salt;
        emit UserSaltGenerated(msg.sender, salt);
    }

    /**
     * @notice Sets or rotates the salted hash of the recovery key.
     * @dev Use only for initial setup or manual rotation (not as part of sensitive actions).
     * @param newHash Salted keccak256(key || salt)
     */
    function setRecoveryKey(bytes32 newHash) external {
        if (_userSalt[msg.sender] == bytes32(0)) revert SaltNotGenerated();
        _recoveryKeyHash[msg.sender] = newHash;
        _recoveryKeySetTime[msg.sender] = block.timestamp;
        emit RecoveryKeyRotated(msg.sender, newHash, block.timestamp);
    }

    /**
     * @notice Sets/changes the recovery wallet with hash rotation.
     * @param recoveryWallet The new recovery wallet address.
     * @param prevHash The previous hash (keccak256(key || salt)), proof of authorization.
     * @param newHash The next salted hash to rotate in (keccak256(nextKey || salt)).
     */
    function setRecoveryWallet(address recoveryWallet, bytes32 prevHash, bytes32 newHash) external {
        if (recoveryWallet == address(0)) revert ZeroAddress();
        _rotateRecoveryKey(prevHash, newHash);
        _recoveryWallet[msg.sender] = recoveryWallet;
        emit RecoveryWalletSet(msg.sender, recoveryWallet);
    }

    /**
     * @notice Activates recovery mode with hash rotation.
     * @param prevHash The previous hash (keccak256(key || salt)), proof of authorization.
     * @param newHash The next salted hash to rotate in (keccak256(nextKey || salt)).
     */
    function activateRecoveryMode(bytes32 prevHash, bytes32 newHash) external {
        _rotateRecoveryKey(prevHash, newHash);
        _recoveryModeActivated[msg.sender] = true;
        emit RecoveryModeActivated(msg.sender);
    }

    /**
     * @notice Deactivates recovery mode with hash rotation.
     * @param prevHash The previous hash (keccak256(key || salt)), proof of authorization.
     * @param newHash The next salted hash to rotate in (keccak256(nextKey || salt)).
     */
    function deactivateRecoveryMode(bytes32 prevHash, bytes32 newHash) external {
        if (!_recoveryModeActivated[msg.sender]) revert NotInRecoveryMode();
        _rotateRecoveryKey(prevHash, newHash);
        _recoveryModeActivated[msg.sender] = false;
        emit RecoveryModeDeactivated(msg.sender);
    }

    /**
     * @notice Marks the user's account as compromised with hash rotation.
     * @param prevHash The previous hash (keccak256(key || salt)), proof of authorization.
     * @param newHash The next salted hash to rotate in (keccak256(nextKey || salt)).
     */
    function markCompromised(bytes32 prevHash, bytes32 newHash) external {
        _rotateRecoveryKey(prevHash, newHash);
        _isCompromised[msg.sender] = true;
        emit AddressCompromised(msg.sender);
    }

    /**
     * @dev Internal hash rotation mechanism, reusable for all sensitive actions.
     *      Ensures hash is one-time use; must be replaced each time.
     * @param prevHash The previous hash for validation.
     * @param newHash The next hash to rotate in.
     */
    function _rotateRecoveryKey(bytes32 prevHash, bytes32 newHash) internal {
        if (_recoveryKeyHash[msg.sender] == bytes32(0)) revert RecoveryKeyNotSet();
        if (prevHash != _recoveryKeyHash[msg.sender]) revert InvalidRecoveryHash();
        require(newHash != bytes32(0) && newHash != prevHash, "Invalid new hash");
        _recoveryKeyHash[msg.sender] = newHash;
        _recoveryKeySetTime[msg.sender] = block.timestamp;
        emit RecoveryKeyRotated(msg.sender, newHash, block.timestamp);
    }

    // --- Getters ---

    /**
     * @notice Returns the current recovery wallet for a user.
     */
    function getRecoveryWallet(address user) external view returns (address) {
        return _recoveryWallet[user];
    }

    /**
     * @notice Returns the salt for a user (used off-chain for hash generation).
     */
    function getUserSalt(address user) external view returns (bytes32) {
        return _userSalt[user];
    }

    /**
     * @notice Returns whether recovery mode is active for a user.
     */
    function isRecoveryModeActive(address user) external view returns (bool) {
        return _recoveryModeActivated[user];
    }

    /**
     * @notice Returns whether a user is marked as compromised.
     */
    function isCompromised(address user) external view returns (bool) {
        return _isCompromised[user];
    }

    /**
     * @notice Returns the last time a recovery key was rotated.
     */
    function getRecoveryKeySetTime(address user) external view returns (uint256) {
        return _recoveryKeySetTime[user];
    }
}
