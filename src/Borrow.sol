// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/*
 Fun little borrow lend by @billyjitsu

 health factor = 1e8 = 100% = 1
 health factor = (collateral value * liquidation Threshold%) / borrows
*/
import "@openzeppelin/contracts/access/Ownable.sol";
import "@api3/contracts/v0.8/interfaces/IProxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Test.sol";

error zeroAmount();
error TransferFailed();
error TokenNotAllowed(address token);
error InsufficientBalance(uint256 available, uint256 required);
error ExceedsMaximumBorrowLimit(uint256 maxAllowed, uint256 requested);
error Overpayment(uint256 available, uint256 requested);
error ContractUnderFunded(uint256 available, uint256 required);
error OverLeveraged(uint256 maxAllowed, uint256 requested);
error NotLiquidatable(uint256 healthFactor, uint256 minHealthFactor);
error IncorrectRepaymentToken(address token);
error NoRewardForLiquidation(uint256 rewardAmount, uint256 halfDebtInUSD);

contract BorrowLend is Ownable {
    address[] public allowedTokens;
    address public nativeTokenProxyAddress;
    address public rewardToken;

    uint256 public constant LIQUIDATION_REWARD = 5;
    uint256 public constant LIQUIDATION_THRESHOLD = 70;
    uint256 public constant MIN_HEALH_FACTOR = 1e8;
    uint256 public stakingAPR = 5;
    uint256 public borrowingAPR = 5;

    mapping(address => address) public priceFeedOfToken;
    mapping(address => uint256) public nativeDeposits;
    mapping(address => mapping(address => uint256)) public deposits;
    mapping(address => mapping(address => uint256)) public borrows;
    mapping(address => mapping(address => uint256)) public interestRates; // look into this
    mapping(address => uint256) public lastUpdateTimestamp;
    mapping(address => uint256) public rewards;

    event DepositedNativeAsset(address indexed account, uint256 indexed amount);
    event DepositedToken(address indexed account, address indexed token, uint256 indexed amount);
    event Borrow(address indexed account, address indexed token, uint256 indexed amount);
    event Repay(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event WithdrawNative(address indexed account, uint256 indexed amount);
    event Liquidate(
        address indexed account,
        address indexed repayToken,
        address indexed rewardToken,
        uint256 halfDebtInEth,
        address liquidator
    );
    event LiquidateForNative(
        address indexed account, address indexed repayToken, uint256 halfDebtInEth, address liquidator
    );
    event AllowedTokenSet(address indexed token, address indexed priceFeed);
    event DepositedRewardToken(address indexed account, address indexed token, uint256 indexed amount);
    event RewardClaimed(address indexed account, address indexed token, uint256 indexed amount);

    constructor() Ownable(msg.sender) {}

    modifier isAllowedToken(address _token) {
        if (priceFeedOfToken[_token] == address(0)) revert TokenNotAllowed(_token);
        _;
    }

    // Set Native Price Feed as it has no address
    function setNativeTokenProxyAddress(address _nativeTokenProxyAddress) external onlyOwner {
        nativeTokenProxyAddress = _nativeTokenProxyAddress;
    }

    function readDataFeed(address _priceFeed) public view returns (uint256, uint256) {
        (int224 value, uint256 timestamp) = IProxy(_priceFeed).read();
        //convert price to UINT256
        uint256 price = uint224(value);
        return (price, timestamp);
    }

    // Chain native asset
    function depositNative() external payable {
        if (msg.value == 0) revert zeroAmount();
        nativeDeposits[msg.sender] += msg.value;
        updateRewardNative(msg.sender);
        emit DepositedNativeAsset(msg.sender, msg.value);
    }

    // Deposit Token
    function depositToken(address _token, uint256 _amount) external isAllowedToken(_token) {
        if (_amount == 0) revert zeroAmount();
        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) revert TransferFailed();
        deposits[msg.sender][_token] += _amount;
        updateReward(msg.sender, _token);
        emit DepositedToken(msg.sender, _token, _amount);
    }

    // Borrow against deposit
    function borrow(address _token, uint256 _amount) external {
        // Calculate the maximum amount that can still be borrowed
        if (_amount > IERC20(_token).balanceOf(address(this))) {
            revert ContractUnderFunded({available: address(this).balance, required: _amount});
        }
        //update balance before transfer
        borrows[msg.sender][_token] += _amount;
        updateReward(msg.sender, _token);
        bool success = IERC20(_token).transfer(msg.sender, _amount);
        if (!success) revert TransferFailed();
        emit Borrow(msg.sender, _token, _amount);
        // check the health factor after borrow
        if (healthFactor(msg.sender) < MIN_HEALH_FACTOR) {
            revert OverLeveraged({maxAllowed: MIN_HEALH_FACTOR, requested: healthFactor(msg.sender)});
        }
    }

    // Pay back debt
    function repay(address _token, uint256 _amount) external payable {
        if (_amount == 0) revert zeroAmount();
        repayFunction(msg.sender, _token, _amount);
        emit Repay(msg.sender, _token, _amount);
    }

    // Internal function to repay if either original user repays or liquidator repays
    function repayFunction(address _account, address _token, uint256 _amount) internal {
        if (_amount > borrows[_account][_token]) {
            revert Overpayment({available: borrows[_account][_token], requested: _amount});
        }

        // bool success = IERC20(_token).transferFrom(_account, address(this), _amount);
        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) revert TransferFailed();
        //Update debt balance after transfer
        borrows[_account][_token] -= _amount;
        updateReward(_account, _token);
    }

    // Liquidate for Token as a deposit
    function liquidate(address _account, address _tokenToRepay, address _rewardToken) external payable {
        if (healthFactor(_account) >= MIN_HEALH_FACTOR) {
            revert NotLiquidatable({healthFactor: healthFactor(_account), minHealthFactor: MIN_HEALH_FACTOR});
        }
        uint256 halfDebt = borrows[_account][_tokenToRepay] / 2;
        uint256 halfDebtInUSD = calculateUSDValue(_tokenToRepay, halfDebt);
        console2.log("Half Debt in USD: ", halfDebtInUSD / 1e18);
        if (halfDebtInUSD == 0) revert IncorrectRepaymentToken(_tokenToRepay);
        uint256 rewardAmountInUSD = (halfDebtInUSD * LIQUIDATION_REWARD) / 100;
        console2.log("Reward Amount in USD: ", rewardAmountInUSD / 1e18);
        uint256 totalRewardAmountInRewardToken =
            calculateTokenValueFromUSD(_rewardToken, rewardAmountInUSD + halfDebtInUSD);
        if (totalRewardAmountInRewardToken == 0) {
            revert NoRewardForLiquidation({rewardAmount: rewardAmountInUSD, halfDebtInUSD: halfDebtInUSD});
        }
        console2.log("Total Reward Amount in Reward Token: ", totalRewardAmountInRewardToken / 1e18);
        repayFunction(_account, _tokenToRepay, halfDebt);
        deposits[_account][_rewardToken] -= totalRewardAmountInRewardToken;
        bool success = IERC20(_rewardToken).transfer(msg.sender, totalRewardAmountInRewardToken);
        if (!success) revert TransferFailed();
        emit Liquidate(_account, _tokenToRepay, _rewardToken, halfDebtInUSD, msg.sender);
    }

    // Liquidate for Native Asset as a deposit
    function liquidateForNative(address _account, address _tokenToRepay) external {
        if (healthFactor(_account) >= MIN_HEALH_FACTOR) {
            revert NotLiquidatable({healthFactor: healthFactor(_account), minHealthFactor: MIN_HEALH_FACTOR});
        }
        uint256 halfDebt = borrows[_account][_tokenToRepay] / 2;
        console2.log("Half Debt: ", halfDebt / 1e18);
        uint256 halfDebtInUSD = calculateUSDValue(_tokenToRepay, halfDebt);
        console2.log("Half Debt in USD: ", halfDebtInUSD / 1e18);
        if (halfDebtInUSD == 0) revert IncorrectRepaymentToken(_tokenToRepay);
        uint256 rewardAmountInUSD = (halfDebtInUSD * LIQUIDATION_REWARD) / 100;
        console2.log("Reward Amount in USD: ", rewardAmountInUSD / 1e18);
        uint256 totalRewardAmountInRewardToken = calculateNativeAssetValueFromUSD(rewardAmountInUSD + halfDebtInUSD);
        console2.log("Total Reward Amount in Reward Token in wei: ", totalRewardAmountInRewardToken);
        if (totalRewardAmountInRewardToken == 0) {
            revert NoRewardForLiquidation({rewardAmount: rewardAmountInUSD, halfDebtInUSD: halfDebtInUSD});
        }
        repayFunction(_account, _tokenToRepay, halfDebt);
        nativeDeposits[_account] -= totalRewardAmountInRewardToken;
        bool success = payable(msg.sender).send(totalRewardAmountInRewardToken);
        if (!success) revert TransferFailed();
        emit LiquidateForNative(_account, _tokenToRepay, halfDebtInUSD, msg.sender);
    }

    // Withdraw Token
    function withdraw(address _token, uint256 _amount) external {
        if (_amount == 0) revert zeroAmount();
        if (_amount > deposits[msg.sender][_token]) {
            revert InsufficientBalance({available: deposits[msg.sender][_token], required: _amount});
        }
        //update balance before transfer
        deposits[msg.sender][_token] -= _amount;
        updateReward(msg.sender, _token);
        bool success = IERC20(_token).transfer(msg.sender, _amount);
        if (!success) revert TransferFailed();
        if (healthFactor(msg.sender) < MIN_HEALH_FACTOR) {
            revert OverLeveraged({maxAllowed: MIN_HEALH_FACTOR, requested: healthFactor(msg.sender)});
        }
        emit Withdraw(msg.sender, _token, _amount);
    }

    // Withdraw Native Asset
    function withdrawNative(uint256 _amount) external {
        if (_amount == 0) revert zeroAmount();
        if (_amount > nativeDeposits[msg.sender]) {
            revert InsufficientBalance({available: nativeDeposits[msg.sender], required: _amount});
        }
        //update balance before transfer
        nativeDeposits[msg.sender] -= _amount;
        updateRewardNative(msg.sender);
        bool success = payable(msg.sender).send(_amount);
        if (!success) revert TransferFailed();
        if (healthFactor(msg.sender) < MIN_HEALH_FACTOR) {
            revert OverLeveraged({maxAllowed: MIN_HEALH_FACTOR, requested: healthFactor(msg.sender)});
        }
        emit WithdrawNative(msg.sender, _amount);
    }

    function updateReward(address _user, address _token) internal {
        uint256 stakedAmount = deposits[_user][_token];
        uint256 borrowedAmount = borrows[_user][_token];
        if (lastUpdateTimestamp[_user] != 0) {
            uint256 timeElapsed = block.timestamp - lastUpdateTimestamp[_user];

            if (stakedAmount > 0) {
                rewards[_user] += stakedAmount * stakingAPR / 100 * timeElapsed / 365 days;
            }
            if (borrowedAmount > 0) {
                rewards[_user] += borrowedAmount * borrowingAPR / 100 * timeElapsed / 365 days;
            }
            console2.log("Update Rewards Value: ", rewards[_user]);
        }

        lastUpdateTimestamp[_user] = block.timestamp;
    }

    function updateRewardNative(address _user) internal {
        uint256 stakedNativeAmount = nativeDeposits[_user];
        if (lastUpdateTimestamp[_user] != 0) {
            uint256 timeElapsed = block.timestamp - lastUpdateTimestamp[_user];
            // Calculate rewards (assuming APR is compounded annually)
            if (stakedNativeAmount > 0) {
                rewards[_user] += stakedNativeAmount * stakingAPR / 100 * timeElapsed / 365 days;
            }
            console2.log("Update Rewards Value: ", rewards[_user]);
        }
        lastUpdateTimestamp[_user] = block.timestamp;
    }

    // Function to set the reward token
    function setRewardToken(address _rewardToken) external onlyOwner {
        rewardToken = _rewardToken;
    }

    function depositRewardToken(address _token, uint256 _amount) external {
        if (_amount == 0) revert zeroAmount();
        bool success = IERC20(_token).transferFrom(msg.sender, address(this), _amount);
        if (!success) revert TransferFailed();
        emit DepositedRewardToken(msg.sender, _token, _amount);
    }

    // Calculate Health Value
    function healthFactor(address _user) public view returns (uint256) {
        (uint256 totalBorrowValue, uint256 totalDepositValue) = userInformation(_user);
        uint256 userCollateral = (totalDepositValue * LIQUIDATION_THRESHOLD) / 100;
        if (totalBorrowValue == 0) return 100e8;
        return (userCollateral * 1e8) / totalBorrowValue;
    }

    function userInformation(address _user) public view returns (uint256, uint256) {
        uint256 totalDepositValue = calculateDepositValue(_user);
        uint256 totalBorrowValue = calculateBorrowValue(_user);
        return (totalBorrowValue, totalDepositValue);
    }

    // Go through all tokens to see deposits and calculate USD value
    function calculateDepositValue(address _user) public view returns (uint256) {
        uint256 totalDepositValue = 0;
        if (nativeDeposits[_user] > 0) {
            totalDepositValue += calculateNativeAssetUSDValue(nativeDeposits[_user]);
        }
        for (uint256 i = 0; i < allowedTokens.length; ++i) {
            address token = allowedTokens[i];
            uint256 depositedTokenAmount = deposits[_user][token];
            if (depositedTokenAmount > 0) {
                totalDepositValue += calculateUSDValue(token, depositedTokenAmount);
            }
        }
        return totalDepositValue;
    }

    // Go through all tokens to see borrows and calculate USD value
    function calculateBorrowValue(address _user) public view returns (uint256) {
        uint256 totalBorrowValue = 0;
        for (uint256 i = 0; i < allowedTokens.length; ++i) {
            address token = allowedTokens[i];
            uint256 borrowedTokenAmount = borrows[_user][token];
            if (borrowedTokenAmount > 0) {
                totalBorrowValue += calculateUSDValue(token, borrowedTokenAmount);
            }
        }
        return totalBorrowValue;
    }

    // Get USD Value from Token Amount
    function calculateUSDValue(address _token, uint256 _amount) public view returns (uint256) {
        uint256 price;
        //  uint256 timestamp;
        (price,) = readDataFeed(priceFeedOfToken[_token]);
        return (_amount * price) / 1e18;
    }

    // Get Token Amount from Native Asset Value
    function calculateNativeAssetUSDValue(uint256 _amount) public view returns (uint256) {
        uint256 price;
        // uint256 ethTimestamp;
        (price,) = readDataFeed(nativeTokenProxyAddress);
        return (_amount * price) / 1e18;
    }

    // Get Token Amount from USD Value
    function calculateTokenValueFromUSD(address _token, uint256 _amount) public view returns (uint256) {
        uint256 price;
        // uint256 timestamp;
        (price,) = readDataFeed(priceFeedOfToken[_token]);
        return (_amount * 1e18) / price;
    }

    // Get Native Token Amount from USD Value
    function calculateNativeAssetValueFromUSD(uint256 _amount) public view returns (uint256) {
        uint256 price;
        // uint256 timestamp;
        (price,) = readDataFeed(nativeTokenProxyAddress);
        return (_amount * 1e18) / price;
    }

    function getCurrentReward(address _user) public view returns (uint256) {
        uint256 totalDeposited = 0;
        uint256 totalBorrowed = 0;

        uint256 currentReward = rewards[_user];
        if (lastUpdateTimestamp[_user] != 0) {
            uint256 timeElapsed = block.timestamp - lastUpdateTimestamp[_user];
            console2.log("Time Elapsed: ", timeElapsed);
            // Sum up all deposits across allowed tokens
            for (uint256 i = 0; i < allowedTokens.length; i++) {
                address token = allowedTokens[i];
                totalDeposited += deposits[_user][token];
                totalBorrowed += borrows[_user][token];
            }

            // Add native deposits if applicable
            totalDeposited += nativeDeposits[_user];

            // Calculate additional rewards based on the time elapsed
            if (totalDeposited > 0) {
                currentReward += totalDeposited * stakingAPR / 100 * timeElapsed / 365 days;
            }
            if (totalBorrowed > 0) {
                currentReward += totalBorrowed * borrowingAPR / 100 * timeElapsed / 365 days;
            }
        }
        return currentReward;
    }

    function claimRewards() external {
        uint256 currentReward = getCurrentReward(msg.sender);
        if (currentReward == 0) revert zeroAmount();
        rewards[msg.sender] = 0;
        lastUpdateTimestamp[msg.sender] = block.timestamp;
        bool success = IERC20(rewardToken).transfer(msg.sender, currentReward);
        if (!success) revert TransferFailed();
        emit RewardClaimed(msg.sender, rewardToken, currentReward);
    }

    // view total amount of ETH in contract for testing
    function getTotalContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    //Set allowed tokens and their price feed
    function setTokensAvailable(address _token, address _priceFeed) external onlyOwner {
        bool exists = false;
        uint256 allowedTokensLength = allowedTokens.length;
        for (uint256 i = 0; i < allowedTokensLength; ++i) {
            if (allowedTokens[i] == _token) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            allowedTokens.push(_token);
        }
        priceFeedOfToken[_token] = _priceFeed;
        emit AllowedTokenSet(_token, _priceFeed);
    }
}
