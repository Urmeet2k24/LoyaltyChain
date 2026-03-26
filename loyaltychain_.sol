// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  LoyaltyChain
 * @notice Interoperable loyalty-point network for multiple brands.
 *         Brands register, mint points to users, and users can redeem
 *         or swap points across brands — all on-chain, no intermediary.
 * @dev    Designed for the Paytm capstone demo. Deployed on Sepolia testnet.
 */
contract LoyaltyChain {

    // ─────────────────────────────────────────────
    //  DATA STRUCTURES
    // ─────────────────────────────────────────────

    struct Brand {
        string  name;           // e.g. "Paytm", "Swiggy"
        address owner;          // wallet that controls this brand
        bool    isActive;       // can be deactivated by owner
        uint256 registeredAt;   // block timestamp
    }

    // brandId => Brand
    mapping(uint256 => Brand) public brands;

    // user address => brandId => point balance
    mapping(address => mapping(uint256 => uint256)) public pointsBalance;

    // user address => brandId => expiry timestamp (0 = no expiry)
    mapping(address => mapping(uint256 => uint256)) public pointsExpiry;

    // swap rate: fromBrandId => toBrandId => rate (scaled by 100)
    // e.g. rate = 80 means 100 points from brand A = 80 points in brand B
    mapping(uint256 => mapping(uint256 => uint256)) public swapRate;

    uint256 public brandCount;       // auto-incrementing brand ID counter
    address public contractOwner;    // deployer / platform admin

    // ─────────────────────────────────────────────
    //  EVENTS  (these appear in the frontend UI)
    // ─────────────────────────────────────────────

    event BrandRegistered(uint256 indexed brandId, string name, address indexed owner);
    event PointsEarned(address indexed user, uint256 indexed brandId, uint256 amount, uint256 expiry);
    event PointsRedeemed(address indexed user, uint256 indexed brandId, uint256 amount);
    event PointsSwapped(
        address indexed user,
        uint256 indexed fromBrandId,
        uint256 indexed toBrandId,
        uint256 amountIn,
        uint256 amountOut
    );
    event SwapRateSet(uint256 fromBrandId, uint256 toBrandId, uint256 rate);
    event BrandStatusUpdated(uint256 indexed brandId, bool isActive);

    // ─────────────────────────────────────────────
    //  MODIFIERS
    // ─────────────────────────────────────────────

    modifier onlyContractOwner() {
        require(msg.sender == contractOwner, "Not platform admin");
        _;
    }

    modifier onlyBrandOwner(uint256 brandId) {
        require(brands[brandId].owner == msg.sender, "Not brand owner");
        _;
    }

    modifier brandExists(uint256 brandId) {
        require(brandId > 0 && brandId <= brandCount, "Brand does not exist");
        _;
    }

    modifier brandActive(uint256 brandId) {
        require(brands[brandId].isActive, "Brand is not active");
        _;
    }

    // ─────────────────────────────────────────────
    //  CONSTRUCTOR
    // ─────────────────────────────────────────────

    constructor() {
        contractOwner = msg.sender;
    }

    // ─────────────────────────────────────────────
    //  BRAND MANAGEMENT
    // ─────────────────────────────────────────────

    /**
     * @notice Register a new brand on the LoyaltyChain network.
     * @param  name Human-readable brand name (e.g. "Paytm")
     * @return brandId The unique ID assigned to this brand
     */
    function registerBrand(string calldata name) external returns (uint256 brandId) {
        require(bytes(name).length > 0, "Brand name cannot be empty");

        brandCount++;
        brandId = brandCount;

        brands[brandId] = Brand({
            name:         name,
            owner:        msg.sender,
            isActive:     true,
            registeredAt: block.timestamp
        });

        emit BrandRegistered(brandId, name, msg.sender);
    }

    /**
     * @notice Toggle a brand's active status (brand owner only).
     */
    function setBrandStatus(uint256 brandId, bool status)
        external
        brandExists(brandId)
        onlyBrandOwner(brandId)
    {
        brands[brandId].isActive = status;
        emit BrandStatusUpdated(brandId, status);
    }

    // ─────────────────────────────────────────────
    //  EARN POINTS  (brand mints to a user)
    // ─────────────────────────────────────────────

    /**
     * @notice Brand mints loyalty points to a user's wallet.
     * @param  user       Recipient address
     * @param  brandId    Which brand's points to mint
     * @param  amount     How many points
     * @param  validDays  Validity in days (0 = never expires)
     */
    function earnPoints(
        address user,
        uint256 brandId,
        uint256 amount,
        uint256 validDays
    )
        external
        brandExists(brandId)
        brandActive(brandId)
        onlyBrandOwner(brandId)
    {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Amount must be > 0");

        // Burn expired points before crediting new ones (keeps ledger clean)
        _clearIfExpired(user, brandId);

        pointsBalance[user][brandId] += amount;

        uint256 expiry = 0;
        if (validDays > 0) {
            expiry = block.timestamp + (validDays * 1 days);
            pointsExpiry[user][brandId] = expiry;
        }

        emit PointsEarned(user, brandId, amount, expiry);
    }

    // ─────────────────────────────────────────────
    //  REDEEM POINTS  (user burns their own points)
    // ─────────────────────────────────────────────

    /**
     * @notice User redeems (burns) their loyalty points.
     * @param  brandId  Which brand's points
     * @param  amount   How many to redeem
     */
    function redeemPoints(uint256 brandId, uint256 amount)
        external
        brandExists(brandId)
        brandActive(brandId)
    {
        require(amount > 0, "Amount must be > 0");
        _clearIfExpired(msg.sender, brandId);

        uint256 balance = pointsBalance[msg.sender][brandId];
        require(balance >= amount, "Insufficient points balance");

        pointsBalance[msg.sender][brandId] -= amount;

        emit PointsRedeemed(msg.sender, brandId, amount);
    }

    // ─────────────────────────────────────────────
    //  SWAP POINTS  (cross-brand exchange — the key innovation!)
    // ─────────────────────────────────────────────

    /**
     * @notice Platform admin sets the swap rate between two brands.
     * @param  fromBrandId  Source brand
     * @param  toBrandId    Target brand
     * @param  rate         Points received per 100 source points (e.g. 80 = 80%)
     */
    function setSwapRate(uint256 fromBrandId, uint256 toBrandId, uint256 rate)
        external
        onlyContractOwner
        brandExists(fromBrandId)
        brandExists(toBrandId)
    {
        require(fromBrandId != toBrandId, "Cannot swap same brand");
        require(rate > 0 && rate <= 200, "Rate must be between 1 and 200");

        swapRate[fromBrandId][toBrandId] = rate;
        emit SwapRateSet(fromBrandId, toBrandId, rate);
    }

    /**
     * @notice Swap points from one brand to another.
     *         amountOut = (amountIn * rate) / 100
     * @param  fromBrandId  Brand to deduct from
     * @param  toBrandId    Brand to credit
     * @param  amountIn     How many source points to swap
     */
    function swapPoints(uint256 fromBrandId, uint256 toBrandId, uint256 amountIn)
        external
        brandExists(fromBrandId)
        brandExists(toBrandId)
        brandActive(fromBrandId)
        brandActive(toBrandId)
    {
        require(fromBrandId != toBrandId, "Cannot swap same brand");
        require(amountIn > 0, "Amount must be > 0");

        uint256 rate = swapRate[fromBrandId][toBrandId];
        require(rate > 0, "No swap route exists for these brands");

        _clearIfExpired(msg.sender, fromBrandId);
        require(
            pointsBalance[msg.sender][fromBrandId] >= amountIn,
            "Insufficient source points"
        );

        uint256 amountOut = (amountIn * rate) / 100;
        require(amountOut > 0, "Output too small");

        pointsBalance[msg.sender][fromBrandId] -= amountIn;
        pointsBalance[msg.sender][toBrandId]   += amountOut;

        emit PointsSwapped(msg.sender, fromBrandId, toBrandId, amountIn, amountOut);
    }

    // ─────────────────────────────────────────────
    //  VIEW FUNCTIONS  (read-only, free to call)
    // ─────────────────────────────────────────────

    /**
     * @notice Get a user's live points for a brand (auto-zeroes if expired).
     */
    function getPoints(address user, uint256 brandId) external view returns (uint256) {
        if (_isExpired(user, brandId)) return 0;
        return pointsBalance[user][brandId];
    }

    /**
     * @notice Get brand info by ID.
     */
    function getBrand(uint256 brandId)
        external
        view
        brandExists(brandId)
        returns (string memory name, address owner, bool isActive, uint256 registeredAt)
    {
        Brand memory b = brands[brandId];
        return (b.name, b.owner, b.isActive, b.registeredAt);
    }

    /**
     * @notice Preview how many points you'd receive for a swap.
     */
    function previewSwap(uint256 fromBrandId, uint256 toBrandId, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 rate)
    {
        rate      = swapRate[fromBrandId][toBrandId];
        amountOut = (amountIn * rate) / 100;
    }

    // ─────────────────────────────────────────────
    //  INTERNAL HELPERS
    // ─────────────────────────────────────────────

    function _isExpired(address user, uint256 brandId) internal view returns (bool) {
        uint256 expiry = pointsExpiry[user][brandId];
        return (expiry != 0 && block.timestamp > expiry);
    }

    function _clearIfExpired(address user, uint256 brandId) internal {
        if (_isExpired(user, brandId)) {
            pointsBalance[user][brandId] = 0;
            pointsExpiry[user][brandId]  = 0;
        }
    }
}
