// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@thirdweb-dev/contracts/extension/Upgradeable.sol";
import "@thirdweb-dev/contracts/extension/PermissionsEnumerable.sol";
import "@thirdweb-dev/contracts/extension/PlatformFee.sol";
import "@thirdweb-dev/contracts/eip/interface/IERC20.sol";
import "./ERC2771ContextUpgradeableModified.sol";

/** 
 * @title BlockBiller
 * @dev Blockbiller subscription contract.
 */
contract BlockBiller is 
    Upgradeable, 
    Initializable,
    PermissionsEnumerable,
    PlatformFee,
    ERC2771ContextUpgradeableModified 
{
    event Withdraw(string _subscriptionId, uint256 _fee, uint256 _balance);
    event Renew(string _subscriberId, string _subscriptionId, address walletAddress, uint256 expiration, uint256 _amount);
    event SubscriptionCreated(string _subscriptionId, uint256 _price, uint256 _duration, IERC20 _token);
    event CurrencyAdded(IERC20 _paytoken, uint256 _costValue);
    event Subscribe(string _subscriberId, string _subscriptionId, uint256 _amount, address walletAddress);
    event Cancel(string _subscriberId, string _subscriptionId, address walletAddress);

	address public deployer;

    struct Subscription {
        uint256 price;
        uint256 duration;
        uint256 balance;
        address owner;
        IERC20 token;
    }

    struct Subscriber {
        string subscriptionId;
        address walletAddress;
        uint256 expiration;
    }

    struct TokenInfo {
        IERC20 payToken;
        uint256 costValue;
    }    

    bytes32 private creatorRole;

    bytes32 private adminRole;

    uint256 private constant MAX_BPS = 10_000;
    
    mapping(string => Subscription) public subscriptions;

    mapping(string => Subscriber) public subscribers;

    mapping(IERC20 => TokenInfo) public acceptedCurrencies;

    function initialize(
        address _platformFeeRecipient, 
        address _defaultAdmin, 
        address[] memory _trustedForwarders,
        uint128 _platformFeeBps
    ) external initializer{
        creatorRole = keccak256("CREATOR_ROLE");
        adminRole = keccak256("ADMIN_ROLE");

        __ERC2771Context_init(_trustedForwarders);
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(adminRole, _defaultAdmin);
        _setRoleAdmin(adminRole, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(creatorRole, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(creatorRole, adminRole);
        _setupPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);

        deployer = _msgSender();
    }

    function addCurrency(IERC20 paytoken, uint256 costvalue) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addCurrency(paytoken, costvalue);
    }

    function subscribe(string memory subscriptionId, string memory subscriberId) external payable {
        Subscriber memory subscriber = subscribers[subscriberId];
        require(subscriber.expiration == 0, "This user is already subscribed");
        _subscribe(subscriptionId, subscriberId, subscriber);
    }

    function cancel(string memory subscriberId) external {
        require(subscribers[subscriberId].walletAddress == _msgSender() || hasRole(adminRole, _msgSender()), "Not authorized");
        _cancel(subscriberId);
    }

    function withdrawBalance(string memory subscriptionId) external payable {
        Subscription storage subscription = subscriptions[subscriptionId];
        require(subscription.owner == _msgSender() || hasRole(adminRole, _msgSender()), "Not authorized");
        require(subscription.balance > 0, "No balance");
        _withdrawBalance(subscriptionId, subscription);
    }    

    function renewSubscription(string memory subscriberId, string memory subscriptionId) external {
        Subscriber storage subscriber = subscribers[subscriberId];
        require(_msgSender() == subscriber.walletAddress || hasRole(adminRole, _msgSender()), "No authorized");
        require(subscriber.expiration <= block.timestamp, "Not ready to renew");
        require(keccak256(abi.encodePacked(subscriber.subscriptionId)) == keccak256(abi.encodePacked(subscriptionId)), "Not subscribed");
        _renewSubscription(subscriberId, subscriptionId, subscriber);
    } 

    function createSubscription(string memory subscriptionId, uint256 duration, uint256 price, IERC20 token) public {
        require(acceptedCurrencies[token].costValue != 0, "Token not accepted");
        require(duration >= 2592000, "Duration too short");
        require(price > 0, "Price can't be zero");
        require(subscriptions[subscriptionId].price == 0, "Subscription already exists");
        _createSubscription(subscriptionId, price, duration, token);
    }

    function _addCurrency(IERC20 _paytoken, uint256 _costvalue) internal virtual {
        acceptedCurrencies[_paytoken].payToken = _paytoken;
        acceptedCurrencies[_paytoken].costValue = _costvalue;   
        emit CurrencyAdded(_paytoken, _costvalue);     
    }

    function _subscribe(string memory _subscriptionId, string memory _subscriberId, Subscriber memory _subscriber) internal virtual {
        uint256 expiration;
        Subscription storage subscription = subscriptions[_subscriptionId];
        TokenInfo storage token = acceptedCurrencies[subscription.token];
        token.payToken.transferFrom(_msgSender(), address(this), subscription.price);
        subscriptions[_subscriptionId].balance += subscription.price;
        expiration = block.timestamp + subscription.duration;
        _subscriber = Subscriber(_subscriptionId, _msgSender(), expiration);
        subscribers[_subscriberId] = _subscriber;
        emit Subscribe(_subscriberId, _subscriptionId, subscription.price, _msgSender());
    }

    function _cancel(string memory subscriberId) internal virtual {
        emit Cancel(subscriberId, subscribers[subscriberId].subscriptionId, _msgSender());
        delete subscribers[subscriberId];
    }

    function _withdrawBalance(string memory _subscriptionId, Subscription storage _subscription) internal virtual {
        (address platformFeeRecipient, uint16 platformFeeBps) = getPlatformFeeInfo();
        uint256 fee = (_subscription.balance * platformFeeBps)/MAX_BPS;
        uint256 _balance = _subscription.balance - fee;
        subscriptions[_subscriptionId].balance = 0;
        _subscription.token.transfer(platformFeeRecipient, fee);
        _subscription.token.transfer(_subscription.owner, _balance);
        emit Withdraw(_subscriptionId, fee, _balance);
    }

    function _renewSubscription(string memory _subscriberId, string memory _subscriptionId, Subscriber storage _subscriber) internal virtual {
        uint256 expiration;
        Subscription storage _subscription = subscriptions[_subscriptionId];
        _subscription.token.transferFrom(_subscriber.walletAddress, address(this), _subscription.price);
        subscriptions[_subscriptionId].balance += _subscription.price;
        expiration = block.timestamp + _subscription.duration;
        subscribers[_subscriberId] = Subscriber(_subscriptionId, subscribers[_subscriberId].walletAddress, expiration); 
        emit Renew(_subscriberId, _subscriptionId, _msgSender(), expiration, _subscription.price);
    }

    function _createSubscription(string memory _subscriptionId, uint256 _price, uint256 _duration, IERC20 _token) internal virtual {
        subscriptions[_subscriptionId] = Subscription(_price, _duration, 0, _msgSender(), _token);
        emit SubscriptionCreated(_subscriptionId, _price, _duration, _token);
    }

    function _canSetPlatformFeeInfo() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    function getBalance(string memory subscriptionId) external view returns (uint256){
        return subscriptions[subscriptionId].balance;
    }

    function _msgSender()
        internal
        view
        virtual
        override(ERC2771ContextUpgradeableModified)
        returns (address sender)
    {
        return ERC2771ContextUpgradeableModified._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ERC2771ContextUpgradeableModified)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeableModified._msgData();
    }

    function setDeployer(address account) external{
        require(_msgSender() == deployer, "Not authorized");
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Not authorized");
        deployer = account;
    }

    function _authorizeUpgrade(address) internal view override {
		require(_msgSender() == deployer, "Not authorized");
	}

    function setTrustedForwarder(address[] memory _trustedForwarders) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < _trustedForwarders.length; i++) {
            _trustedForwarder[_trustedForwarders[i]] = true;
        }
    }
}