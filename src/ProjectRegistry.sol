// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ProjectRegistry
 * @notice Central registry for projects seeking funding from multiple PCC pools
 * @dev Projects can receive contributions from any number of pools
 */
contract ProjectRegistry is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum ProjectStatus {
        FUNDING,    // Actively seeking contributions
        FUNDED,     // Target reached
        CANCELLED,  // Creator cancelled
        COMPLETED   // Project delivered
    }

    enum ContributionStatus {
        PENDING,    // Waiting for pool vote
        APPROVED,   // Pool approved, waiting for execution
        FUNDED,     // Funds received
        REJECTED    // Pool rejected
    }

    // ============ Structs ============

    struct Project {
        uint256 id;
        address creator;
        string name;
        string descriptionUri;      // IPFS link
        address fundingToken;       // USDC, ETH (address(0)), etc.
        uint256 targetAmount;
        uint256 raisedAmount;
        uint256 deadline;
        ProjectStatus status;
        uint256 createdAt;
        string websiteUrl;
        string twitterUrl;
    }

    struct Contribution {
        uint256 id;
        uint256 projectId;
        address pool;               // Pool contract address
        uint256 amount;
        ContributionStatus status;
        uint256 createdAt;
        uint256 fundedAt;
    }

    // ============ State Variables ============

    uint256 public nextProjectId;
    uint256 public nextContributionId;
    
    mapping(uint256 => Project) public projects;
    mapping(uint256 => Contribution) public contributions;
    
    // Project ID => Contribution IDs
    mapping(uint256 => uint256[]) public projectContributions;
    
    // Pool => Contribution IDs
    mapping(address => uint256[]) public poolContributions;
    
    // Project ID => Pool => has contributed
    mapping(uint256 => mapping(address => bool)) public hasPoolContributed;
    
    // Registered pools that can contribute
    mapping(address => bool) public registeredPools;
    
    address public admin;
    uint256 public platformFeeBps; // e.g., 250 = 2.5%
    address public feeRecipient;

    // ============ Events ============

    event ProjectCreated(uint256 indexed projectId, address indexed creator, uint256 targetAmount, address fundingToken);
    event ProjectCancelled(uint256 indexed projectId);
    event ProjectFunded(uint256 indexed projectId);
    event ProjectCompleted(uint256 indexed projectId);
    
    event ContributionProposed(uint256 indexed contributionId, uint256 indexed projectId, address indexed pool, uint256 amount);
    event ContributionApproved(uint256 indexed contributionId);
    event ContributionRejected(uint256 indexed contributionId);
    event ContributionFunded(uint256 indexed contributionId, uint256 amount);
    
    event PoolRegistered(address indexed pool);
    event PoolUnregistered(address indexed pool);
    event FeesUpdated(uint256 feeBps, address recipient);

    // ============ Errors ============

    error NotAdmin();
    error NotCreator();
    error NotPool();
    error NotRegisteredPool();
    error ProjectNotFound();
    error ProjectNotFunding();
    error ProjectExpired();
    error ContributionNotFound();
    error InvalidStatus();
    error AlreadyContributed();
    error ZeroAmount();
    error InvalidAddress();
    error TargetExceeded();

    // ============ Modifiers ============

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyRegisteredPool() {
        if (!registeredPools[msg.sender]) revert NotRegisteredPool();
        _;
    }

    // ============ Constructor ============

    constructor(address _admin, address _feeRecipient, uint256 _platformFeeBps) {
        admin = _admin;
        feeRecipient = _feeRecipient;
        platformFeeBps = _platformFeeBps;
    }

    // ============ Admin Functions ============

    function registerPool(address pool) external onlyAdmin {
        if (pool == address(0)) revert InvalidAddress();
        registeredPools[pool] = true;
        emit PoolRegistered(pool);
    }

    function unregisterPool(address pool) external onlyAdmin {
        registeredPools[pool] = false;
        emit PoolUnregistered(pool);
    }

    function updateFees(uint256 _feeBps, address _recipient) external onlyAdmin {
        platformFeeBps = _feeBps;
        feeRecipient = _recipient;
        emit FeesUpdated(_feeBps, _recipient);
    }

    function updateAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    // ============ Project Functions ============

    /**
     * @notice Create a new project seeking funding
     * @param name Project name
     * @param descriptionUri IPFS link to full description
     * @param fundingToken Token to receive (address(0) for ETH)
     * @param targetAmount Total funding goal
     * @param durationDays Days until deadline
     * @param websiteUrl Project website
     * @param twitterUrl Project twitter
     */
    function createProject(
        string calldata name,
        string calldata descriptionUri,
        address fundingToken,
        uint256 targetAmount,
        uint256 durationDays,
        string calldata websiteUrl,
        string calldata twitterUrl
    ) external returns (uint256) {
        if (targetAmount == 0) revert ZeroAmount();

        uint256 projectId = nextProjectId++;

        projects[projectId] = Project({
            id: projectId,
            creator: msg.sender,
            name: name,
            descriptionUri: descriptionUri,
            fundingToken: fundingToken,
            targetAmount: targetAmount,
            raisedAmount: 0,
            deadline: block.timestamp + (durationDays * 1 days),
            status: ProjectStatus.FUNDING,
            createdAt: block.timestamp,
            websiteUrl: websiteUrl,
            twitterUrl: twitterUrl
        });

        emit ProjectCreated(projectId, msg.sender, targetAmount, fundingToken);

        return projectId;
    }

    /**
     * @notice Cancel a project (only by creator, only if no funds raised)
     * @param projectId Project to cancel
     */
    function cancelProject(uint256 projectId) external {
        Project storage project = projects[projectId];
        
        if (project.creator != msg.sender) revert NotCreator();
        if (project.status != ProjectStatus.FUNDING) revert InvalidStatus();
        if (project.raisedAmount > 0) revert InvalidStatus(); // Can't cancel if funds received
        
        project.status = ProjectStatus.CANCELLED;
        emit ProjectCancelled(projectId);
    }

    /**
     * @notice Mark project as completed (only by creator)
     * @param projectId Project to complete
     */
    function completeProject(uint256 projectId) external {
        Project storage project = projects[projectId];
        
        if (project.creator != msg.sender) revert NotCreator();
        if (project.status != ProjectStatus.FUNDED) revert InvalidStatus();
        
        project.status = ProjectStatus.COMPLETED;
        emit ProjectCompleted(projectId);
    }

    // ============ Contribution Functions ============

    /**
     * @notice Propose a contribution from a pool (called by pool contract)
     * @param projectId Project to fund
     * @param amount Amount to contribute
     */
    function proposeContribution(uint256 projectId, uint256 amount) external onlyRegisteredPool returns (uint256) {
        Project storage project = projects[projectId];
        
        if (project.status != ProjectStatus.FUNDING) revert ProjectNotFunding();
        if (block.timestamp >= project.deadline) revert ProjectExpired();
        if (amount == 0) revert ZeroAmount();
        if (hasPoolContributed[projectId][msg.sender]) revert AlreadyContributed();
        
        // Don't allow contributions that would exceed target
        if (project.raisedAmount + amount > project.targetAmount) {
            revert TargetExceeded();
        }

        uint256 contributionId = nextContributionId++;

        contributions[contributionId] = Contribution({
            id: contributionId,
            projectId: projectId,
            pool: msg.sender,
            amount: amount,
            status: ContributionStatus.PENDING,
            createdAt: block.timestamp,
            fundedAt: 0
        });

        projectContributions[projectId].push(contributionId);
        poolContributions[msg.sender].push(contributionId);
        hasPoolContributed[projectId][msg.sender] = true;

        emit ContributionProposed(contributionId, projectId, msg.sender, amount);

        return contributionId;
    }

    /**
     * @notice Update contribution status after pool vote (called by pool)
     * @param contributionId Contribution to update
     * @param approved Whether pool approved the contribution
     */
    function updateContributionStatus(uint256 contributionId, bool approved) external {
        Contribution storage contribution = contributions[contributionId];
        
        if (contribution.pool != msg.sender) revert NotPool();
        if (contribution.status != ContributionStatus.PENDING) revert InvalidStatus();

        if (approved) {
            contribution.status = ContributionStatus.APPROVED;
            emit ContributionApproved(contributionId);
        } else {
            contribution.status = ContributionStatus.REJECTED;
            hasPoolContributed[contribution.projectId][msg.sender] = false;
            emit ContributionRejected(contributionId);
        }
    }

    /**
     * @notice Execute a contribution (transfer funds from pool to project)
     * @param contributionId Contribution to execute
     */
    function executeContribution(uint256 contributionId) external payable nonReentrant {
        Contribution storage contribution = contributions[contributionId];
        Project storage project = projects[contribution.projectId];
        
        if (contribution.status != ContributionStatus.APPROVED) revert InvalidStatus();
        if (project.status != ProjectStatus.FUNDING) revert ProjectNotFunding();

        contribution.status = ContributionStatus.FUNDED;
        contribution.fundedAt = block.timestamp;

        uint256 amount = contribution.amount;
        uint256 fee = (amount * platformFeeBps) / 10000;
        uint256 netAmount = amount - fee;

        if (project.fundingToken == address(0)) {
            // ETH
            require(msg.value == amount, "Incorrect ETH amount");
            
            if (fee > 0) {
                (bool feeSuccess,) = feeRecipient.call{ value: fee }("");
                require(feeSuccess, "Fee transfer failed");
            }
            
            (bool success,) = project.creator.call{ value: netAmount }("");
            require(success, "Transfer failed");
        } else {
            // ERC20
            IERC20(project.fundingToken).safeTransferFrom(msg.sender, address(this), amount);
            
            if (fee > 0) {
                IERC20(project.fundingToken).safeTransfer(feeRecipient, fee);
            }
            
            IERC20(project.fundingToken).safeTransfer(project.creator, netAmount);
        }

        project.raisedAmount += amount;

        emit ContributionFunded(contributionId, amount);

        // Check if fully funded
        if (project.raisedAmount >= project.targetAmount) {
            project.status = ProjectStatus.FUNDED;
            emit ProjectFunded(contribution.projectId);
        }
    }

    // ============ View Functions ============

    function getProject(uint256 projectId) external view returns (Project memory) {
        return projects[projectId];
    }

    function getContribution(uint256 contributionId) external view returns (Contribution memory) {
        return contributions[contributionId];
    }

    function getProjectContributions(uint256 projectId) external view returns (uint256[] memory) {
        return projectContributions[projectId];
    }

    function getPoolContributions(address pool) external view returns (uint256[] memory) {
        return poolContributions[pool];
    }

    function getProjectProgress(uint256 projectId) external view returns (
        uint256 raised,
        uint256 target,
        uint256 percentFunded,
        uint256 contributionCount
    ) {
        Project storage project = projects[projectId];
        raised = project.raisedAmount;
        target = project.targetAmount;
        percentFunded = target > 0 ? (raised * 10000) / target : 0;
        contributionCount = projectContributions[projectId].length;
    }

    function isProjectActive(uint256 projectId) external view returns (bool) {
        Project storage project = projects[projectId];
        return project.status == ProjectStatus.FUNDING && block.timestamp < project.deadline;
    }

    // Allow receiving ETH
    receive() external payable {}
}
