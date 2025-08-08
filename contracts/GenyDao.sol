// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { IGenyAllocation } from "./interfaces/IGenyAllocation.sol";
import { IGenyBurnManager } from "./interfaces/IGenyBurnManager.sol";

/// @title GenyDAO
/// @author compez.eth
/// @notice Manages Genyleap Improvement Proposals (GIP) for decentralized governance in the Genyleap ecosystem.
/// @dev Implements voting with 20% quorum for normal proposals and 50% for sensitive ones, 7-day voting period.
/// The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
/// Uses UUPS proxy pattern for upgradability.
/// Assumes GENY token supports SafeERC20 and IVotes for transfers and voting.
/// @custom:security-contact security@genyleap.com
contract GenyDAO is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    IVotes public token; // GENY token contract with IVotes interface
    address public burnManager; // GenyBurnManager for token burning
    address public allocationManager; // GenyAllocation for treasury management
    uint32 public minProposingPowerNormalPercent; // Basis points (0.1% = 10)
    uint32 public minProposingPowerSensitivePercent; // Basis points (1% = 100)
    uint256 public minVotingPower; // Minimum tokens to vote (256 tokens)

    /// @notice Investor label types for proposers
    enum InvestorLabel { None, Founder, CoreInvestor, CommunityAdvocate, StandardHolder }

    /// @dev Stores proposal details with optimized storage
    struct Proposal {
        address proposer;
        string description;
        uint48 startTime;
        uint48 endTime;
        uint96 forVotes;
        uint96 againstVotes;
        uint96 totalVotes;
        bool executed;
        bool isSensitive;
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        uint256 snapshotBlock; // Block number for vote snapshot
    }

    mapping(uint256 => Proposal) public proposals; // Proposal ID to details
    mapping(uint256 => mapping(address => bool)) public hasVoted; // Tracks voting status
    mapping(address => InvestorLabel) public investorLabels; // Investor labels
    uint256 public proposalCount; // Total number of proposals

    // Constants
    uint32 private constant QUORUM_NORMAL = 20_00; // 20% (2000 basis points)
    uint32 private constant QUORUM_SENSITIVE = 50_00; // 50% (5000 basis points)
    uint48 private constant VOTING_PERIOD = 7 days;
    uint32 private constant BURN_MAX_PERCENT = 10_00; // 10% (1000 basis points)
    uint32 private constant MIN_PROPOSING_PERCENT_MIN = 1; // 0.01% (1 basis point)
    uint32 private constant MIN_PROPOSING_PERCENT_MAX = 1000; // 10% (1000 basis points)
    uint256 private constant MIN_VOTING_POWER_MIN = 25 * 1e18;
    uint256 private constant MIN_VOTING_POWER_MAX = 2560 * 1e18;

    /// @notice Emitted when a new GIP is created
    event ProposalCreated(uint256 indexed proposalId, address proposer, InvestorLabel proposerLabel, string description, bool isSensitive, uint48 startTime, uint256 snapshotBlock);
    /// @notice Emitted when a vote is cast
    event Voted(uint256 indexed proposalId, address voter, bool support, uint96 weight);
    /// @notice Emitted when a proposal is executed
    event ProposalExecuted(uint256 indexed proposalId);
    /// @notice Emitted when tokens are burned
    event TokensBurned(uint256 indexed proposalId, uint256 amount);
    /// @notice Emitted when proposing power percentage is updated
    event MinProposingPowerPercentUpdated(bool isSensitive, uint32 oldPercent, uint32 newPercent);
    /// @notice Emitted when minimum voting power is updated
    event MinVotingPowerUpdated(uint256 oldPower, uint256 newPower);
    /// @notice Emitted when an investor label is updated
    event InvestorLabelUpdated(address indexed investor, InvestorLabel oldLabel, InvestorLabel newLabel);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the DAO contract
    /// @dev The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
    /// @param _token Address of the GENY token contract (must support IVotes)
    /// @param _owner Address of the initial owner (multisig)
    /// @param _burnManager Address of the GenyBurnManager contract
    /// @param _allocationManager Address of the GenyAllocation contract
    function initialize(
        address _token,
        address _owner,
        address _burnManager,
        address _allocationManager
    ) external initializer {
        _validateAddresses(_token, _owner, _burnManager, _allocationManager);
        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        token = IVotes(_token);
        burnManager = _burnManager;
        allocationManager = _allocationManager;
        minProposingPowerNormalPercent = 10; // 0.1%
        minProposingPowerSensitivePercent = 100; // 1%
        minVotingPower = 256 * 1e18;
    }

    /// @notice Returns the circulating supply using GenyAllocation's released tokens
    /// @return The circulating supply in tokens
    function getCirculatingSupply() public view returns (uint256) {
        return IGenyAllocation(allocationManager).getTotalReleasedTokens();
    }

    /// @notice Returns the minimum proposing power for a proposal
    /// @param isSensitive True if the proposal is sensitive
    /// @return The minimum tokens required
    function getMinProposingPower(bool isSensitive) public view returns (uint256) {
        return (getCirculatingSupply() * (isSensitive ? minProposingPowerSensitivePercent : minProposingPowerNormalPercent)) / 1e4;
    }

    /// @notice Creates a new GIP
    /// @dev Callable by any user with sufficient token balance at the current block
    /// @param description Proposal description
    /// @param isSensitive True if the proposal is sensitive
    /// @param targets Contract addresses to call
    /// @param values ETH values for each call
    /// @param calldatas Data for each call
    /// @param startTime The start time for voting (must be >= block.timestamp)
    function createProposal(
        string memory description,
        bool isSensitive,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        uint48 startTime
    ) external whenNotPaused {
        uint256 snapshotBlock = block.number;
        require(token.getPastVotes(msg.sender, snapshotBlock) >= getMinProposingPower(isSensitive), "Insufficient proposing power");
        require(targets.length == values.length && values.length == calldatas.length, "Invalid proposal data");
        require(startTime >= block.timestamp, "Start time must be in the future or present");
        proposals[++proposalCount] = Proposal({
            proposer: msg.sender,
            description: description,
            startTime: startTime,
            endTime: startTime + VOTING_PERIOD,
            forVotes: 0,
            againstVotes: 0,
            totalVotes: 0,
            executed: false,
            isSensitive: isSensitive,
            targets: targets,
            values: values,
            calldatas: calldatas,
            snapshotBlock: snapshotBlock
        });
        emit ProposalCreated(proposalCount, msg.sender, investorLabels[msg.sender], description, isSensitive, startTime, snapshotBlock);
    }

    /// @notice Casts a vote on a proposal
    /// @dev Callable by any user with sufficient token balance at proposal snapshot block
    /// @param proposalId The ID of the proposal
    /// @param support True for supporting, false for opposing
    function vote(uint256 proposalId, bool support) external nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.startTime && block.timestamp <= proposal.endTime, "Voting not active");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        uint96 weight = uint96(token.getPastVotes(msg.sender, proposal.snapshotBlock));
        require(weight >= minVotingPower, "Insufficient voting power");
        hasVoted[proposalId][msg.sender] = true;
        proposal.totalVotes += weight;
        if (support) proposal.forVotes += weight;
        else proposal.againstVotes += weight;
        emit Voted(proposalId, msg.sender, support, weight);
    }

    /// @notice Executes a proposal after voting ends (no timelock, onlyOwner can execute)
    /// @dev Only the owner (multisig) can execute proposals for security.
    /// @param proposalId The ID of the proposal
    function executeProposal(uint256 proposalId) external onlyOwner nonReentrant whenNotPaused {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp > proposal.endTime, "Voting not ended");
        require(!proposal.executed, "Already executed");
        require(proposal.forVotes > proposal.againstVotes, "Proposal rejected");
        uint32 quorumPercent = proposal.isSensitive ? QUORUM_SENSITIVE : QUORUM_NORMAL;
        require(proposal.totalVotes >= (getCirculatingSupply() * quorumPercent) / 1e4, "Quorum not met");
        proposal.executed = true;

        // Execute each call atomically, revert if any fails
        for (uint256 i = 0; i < proposal.targets.length; i++) {
            (bool success, ) = proposal.targets[i].call{value: proposal.values[i]}(proposal.calldatas[i]);
            require(success, "Proposal call failed");
        }
        emit ProposalExecuted(proposalId);
    }

    /// @notice Updates the minimum proposing power percentage
    /// @dev Only callable by owner (multisig)
    /// @param isSensitive True for sensitive proposals, false for normal
    /// @param newPercent New percentage (in basis points)
    function updateMinProposingPowerPercent(bool isSensitive, uint32 newPercent) external onlyOwner {
        require(newPercent >= MIN_PROPOSING_PERCENT_MIN && newPercent <= MIN_PROPOSING_PERCENT_MAX, "Invalid proposing percent");
        if (isSensitive) {
            uint32 oldPercent = minProposingPowerSensitivePercent;
            minProposingPowerSensitivePercent = newPercent;
            emit MinProposingPowerPercentUpdated(true, oldPercent, newPercent);
        } else {
            uint32 oldPercent = minProposingPowerNormalPercent;
            minProposingPowerNormalPercent = newPercent;
            emit MinProposingPowerPercentUpdated(false, oldPercent, newPercent);
        }
    }

    /// @notice Updates the minimum voting power
    /// @dev Only callable by owner (multisig)
    /// @param newPower New minimum voting power
    function updateMinVotingPower(uint256 newPower) external onlyOwner {
        require(newPower >= MIN_VOTING_POWER_MIN && newPower <= MIN_VOTING_POWER_MAX, "Invalid voting power");
        emit MinVotingPowerUpdated(minVotingPower, newPower);
        minVotingPower = newPower;
    }

    /// @notice Assigns or updates an investor label by owner (multisig)
    /// @param investor Address of the investor
    /// @param label New label to assign
    function setInvestorLabel(address investor, InvestorLabel label) external onlyOwner {
        _updateInvestorLabel(investor, label);
    }

    /// @notice Burns tokens from the treasury
    /// @dev Only callable by the owner (multisig); transfers tokens to allocationManager for burning
    /// @param amount Amount of tokens to burn
    function burnTokens(uint256 amount) external onlyOwner nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        require(amount <= (IERC20(address(token)).balanceOf(address(this)) * BURN_MAX_PERCENT) / 1e4, "Exceeds max burn limit");
        require(IERC20(address(token)).balanceOf(address(this)) >= amount, "Insufficient balance");
        // Transfer tokens to allocationManager for burning
        IERC20(address(token)).safeTransfer(allocationManager, amount);
        IGenyBurnManager(burnManager).burnFromContract(amount);
        emit TokensBurned(proposalCount, amount);
    }

    /// @notice Pauses the contract
    /// @dev Only callable by the owner (multisig)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by the owner (multisig)
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @dev Only callable by the owner (multisig)
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Validates initialization addresses
    function _validateAddresses(address _token, address _owner, address _burnManager, address _allocationManager) private pure {
        require(_token != address(0) && _owner != address(0) && _burnManager != address(0) && _allocationManager != address(0), "Invalid address");
    }

    /// @dev Updates investor label with event emission
    function _updateInvestorLabel(address investor, InvestorLabel label) private {
        require(investor != address(0), "Invalid investor address");
        emit InvestorLabelUpdated(investor, investorLabels[investor], label);
        investorLabels[investor] = label;
    }

    /// @notice Returns the targets array for a proposal
    /// @param proposalId The ID of the proposal
    /// @return The array of target addresses
    function getProposalTargets(uint256 proposalId) external view returns (address[] memory) {
        return proposals[proposalId].targets;
    }

    /// @notice Returns the values array for a proposal
    /// @param proposalId The ID of the proposal
    /// @return The array of values
    function getProposalValues(uint256 proposalId) external view returns (uint256[] memory) {
        return proposals[proposalId].values;
    }

    /// @notice Returns the calldatas array for a proposal
    /// @param proposalId The ID of the proposal
    /// @return The array of calldatas
    function getProposalCalldatas(uint256 proposalId) external view returns (bytes[] memory) {
        return proposals[proposalId].calldatas;
    }

    /// @dev Storage gap for future variable additions (OZ pattern).
    /// If you add new state variables at the end in a future upgrade,
    /// decrease the length of this array by the same number of slots.
    uint256[50] private __gap;
}
