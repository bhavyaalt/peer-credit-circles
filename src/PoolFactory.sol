// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Pool.sol";
import "./ProjectRegistry.sol";

/**
 * @title PoolFactory
 * @notice Factory contract to create and track Peer Credit Circle pools
 */
contract PoolFactory {
    // ============ Events ============

    event PoolCreated(
        address indexed pool,
        address indexed creator,
        string name,
        address depositToken
    );
    event ProjectRegistryUpdated(address indexed registry);

    // ============ State ============

    address[] public pools;
    mapping(address => bool) public isPool;
    mapping(address => address[]) public userPools; // pools a user is admin of
    
    address public admin;
    ProjectRegistry public projectRegistry;

    // ============ Constructor ============

    constructor() {
        admin = msg.sender;
    }

    // ============ Admin Functions ============

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    function setProjectRegistry(address _registry) external onlyAdmin {
        projectRegistry = ProjectRegistry(payable(_registry));
        emit ProjectRegistryUpdated(_registry);
    }

    function updateAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    // ============ Functions ============

    /**
     * @notice Create a new Peer Credit Circle pool
     * @param name Pool name
     * @param depositToken Address of deposit token (address(0) for ETH)
     * @param minDeposit Minimum deposit amount
     * @param votingPeriod Voting duration in seconds
     * @param quorumBps Minimum participation in basis points
     * @param approvalThresholdBps Approval threshold in basis points
     * @param guardianThresholdBps Guardian threshold in basis points
     * @param guardians Initial guardian addresses
     * @return pool Address of the created pool
     */
    function createPool(
        string calldata name,
        address depositToken,
        uint256 minDeposit,
        uint256 votingPeriod,
        uint256 quorumBps,
        uint256 approvalThresholdBps,
        uint256 guardianThresholdBps,
        address[] calldata guardians
    ) external returns (address pool) {
        Pool.PoolConfig memory config = Pool.PoolConfig({
            name: name,
            depositToken: depositToken,
            minDeposit: minDeposit,
            votingPeriod: votingPeriod,
            quorumBps: quorumBps,
            approvalThresholdBps: approvalThresholdBps,
            guardianThresholdBps: guardianThresholdBps
        });

        Pool newPool = new Pool(config, msg.sender, guardians);
        pool = address(newPool);

        pools.push(pool);
        isPool[pool] = true;
        userPools[msg.sender].push(pool);

        // Set project registry if configured
        if (address(projectRegistry) != address(0)) {
            newPool.setProjectRegistry(address(projectRegistry));
            // Register pool with ProjectRegistry
            projectRegistry.registerPool(pool);
        }

        emit PoolCreated(pool, msg.sender, name, depositToken);
    }

    /**
     * @notice Get all created pools
     */
    function getAllPools() external view returns (address[] memory) {
        return pools;
    }

    /**
     * @notice Get pools count
     */
    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    /**
     * @notice Get pools created by a user
     * @param user Address to check
     */
    function getUserPools(address user) external view returns (address[] memory) {
        return userPools[user];
    }
}
