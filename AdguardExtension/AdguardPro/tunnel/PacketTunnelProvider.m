/**
    This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
    Copyright © 2015-2016 Performix LLC. All rights reserved.
 
    Adguard for iOS is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
 
    Adguard for iOS is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
 
    You should have received a copy of the GNU General Public License
    along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

#import "PacketTunnelProvider.h"

#import <UIKit/UIDevice.h>

#import "ACommons/ACLang.h"
#import "ACommons/ACNetwork.h"
#import "APTunnelConnectionsHandler.h"
#import "APSharedResources.h"
#import "APTunnelConnectionsHandler.h"
#import "APDnsServerObject.h"

#import "ASDFilterObjects.h"
#import "AESAntibanner.h"
#import "AEService.h"
#import "APWhitelistDomainObject.h"
#import "AEBlacklistDomainObject.h"
#import "ASDatabase.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <resolv.h>
#include <dns.h>
#include <net/if.h>

/////////////////////////////////////////////////////////////////////
#pragma mark - PacketTunnelProvider Constants

NSString *APTunnelProviderErrorDomain = @"APTunnelProviderErrorDomain";

#define V_REMOTE_ADDRESS                        @"127.1.1.1"

#define V_INTERFACE_IPV4_ADDRESS                @"172.16.209.2"
#define V_INTERFACE_IPV4_MASK                   @"255.255.255.252"
#define V_INTERFACE_IPV4_FULL_MASK              @"255.255.255.255"

#define V_INTERFACE_IPV6_ADDRESS                @"fd12:1:1:1::2"
#define V_INTERFACE_IPV6_MASK                   @(64)
#define V_INTERFACE_IPV6_FULL_MASK              @(128)

#define TIME_INTERVAL_FOR_WARNING_MESSAGE       30 //seconds

/////////////////////////////////////////////////////////////////////
#pragma mark - PacketTunnelProvider

@implementation PacketTunnelProvider{
    
    void (^pendingStartCompletion)(NSError *error);
    void (^pendingStopCompletion)(void);
    
    APDnsServerObject *_currentServer;
    BOOL    _localFiltering;
    BOOL    _isRemoteServer;
    
    Reachability *_reachabilityHandler;
    APTunnelConnectionsHandler *_connectionHandler;
}

+ (void)initialize{
    
    if (self == [PacketTunnelProvider class]) {
        
        // Init Logger
        [[ACLLogger singleton] initLogger:[AESharedResources sharedAppLogsURL]];
        
#if DEBUG
        [[ACLLogger singleton] setLogLevel:ACLLVerboseLevel];
#endif
        
    }
}

- (id)init {
    
    self = [super init];
    if (self) {
        
        // Create connection handler
        _connectionHandler = [[APTunnelConnectionsHandler alloc] initWithProvider:self];
        [_connectionHandler setDnsActivityLoggingEnabled:[[AESharedResources sharedDefaults] boolForKey:APDefaultsDnsLoggingEnabled]];

        _reachabilityHandler = [Reachability reachabilityForInternetConnection];
        
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachNotify:) name:kReachabilityChangedNotification object:nil];
    }
    return self;
}

/////////////////////////////////////////////////////////////////////
#pragma mark Controll connection methods

- (void)startTunnelWithOptions:(NSDictionary *)options completionHandler:(void (^)(NSError *))completionHandler
{
    DDLogInfo(@"(PacketTunnelProvider) Start Tunnel Event");
    
    pendingStartCompletion = completionHandler;
    
    [_reachabilityHandler startNotifier];
    
    // Getting DNS
    NETunnelProviderProtocol *protocol = (NETunnelProviderProtocol *)self.protocolConfiguration;
    
    _currentServer = nil;
    NSData *currentServerData = protocol.providerConfiguration[APVpnManagerParameterRemoteDnsServer];
    if (currentServerData) {

        _currentServer = [NSKeyedUnarchiver unarchiveObjectWithData:currentServerData];
    }
    
    //protection for bad or old configuration
    if (_currentServer == nil) {

        @autoreleasepool {
            _currentServer = APVPNManager.predefinedDnsServers[APVPN_MANAGER_DEFAULT_REMOTE_DNS_SERVER_INDEX];
            _localFiltering = NO;
            _isRemoteServer = YES;
        }
    }
    else {
        
        _localFiltering = [protocol.providerConfiguration[APVpnManagerParameterLocalFiltering] boolValue];
        _isRemoteServer = ! [_currentServer.tag isEqualToString:APDnsServerTagLocal];
    }
    
    
    DDLogInfo(@"PacketTunnelProvider) Start Tunnel with configuration: %@%@%@", _currentServer.serverName,
              (_localFiltering ? @", LocalFiltering" : @""), (_isRemoteServer ? @", isRemoteServer" : @""));
    
    [self reloadWhitelistBlacklistDomain];

    //create empty tunnel settings
    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:V_REMOTE_ADDRESS];
    
    DDLogInfo(@"(PacketTunnelProvider) Empty tunnel settings created.");
    
    // Check configuration
    if (_localFiltering == NO && [_currentServer.tag isEqualToString:APDnsServerTagLocal]) {
        
        DDLogError(@"(PacketTunnelProvider) Bad configuration. Attempting set localFiltering = NO and to use system DNS settings.");
    }
    else if (! (_currentServer.ipv4Addresses.count || _currentServer.ipv6Addresses.count)) {
        
        DDLogError(@"(PacketTunnelProvider) Can't obtain DNS addresses from protocol configuration.");
    }
    else {
        
        settings = [self createTunnelSettings];
        DDLogInfo(@"(PacketTunnelProvider) Tunnel settings filled.");
    }
    
    
    // SETs network settings
    __typeof__(self) __weak wSelf = self;
    [self setTunnelNetworkSettings:settings completionHandler:^(NSError *_Nullable error) {
        
        __typeof__(self) sSelf = wSelf;
        
        @synchronized (sSelf->_connectionHandler) {
            if (sSelf->_connectionHandler) {
                [sSelf->_connectionHandler startHandlingPackets];
                DDLogInfo(@"(PacketTunnelProvider) connectionHandler started handling packets.");
            }
        }
        
        
        DDLogInfo(@"(PacketTunnelProvider) Call pendingStartCompletion.");
        sSelf->pendingStartCompletion(error);
        sSelf->pendingStartCompletion = nil;
        
        [sSelf logNetworkInterfaces];
    }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler
{
	// Add code here to start the process of stopping the tunnel.
    DDLogInfo(@"(PacketTunnelProvider) Stop Tunnel Event");
    
    NSString *reasonString;
    
    switch (reason) {
        case NEProviderStopReasonNone:
            reasonString = @"NEProviderStopReasonNone No specific reason. ";
            break;
        case NEProviderStopReasonUserInitiated:
            reasonString = @"NEProviderStopReasonUserInitiated The user stopped the provider. ";
            break;
        case NEProviderStopReasonProviderFailed:
            reasonString = @"NEProviderStopReasonProviderFailed The provider failed. ";
            break;
        case NEProviderStopReasonNoNetworkAvailable:
            reasonString = @"NEProviderStopReasonNoNetworkAvailable There is no network connectivity. ";
            break;
        case NEProviderStopReasonUnrecoverableNetworkChange:
            reasonString = @"NEProviderStopReasonUnrecoverableNetworkChange The device attached to a new network. ";
            break;
        case NEProviderStopReasonProviderDisabled:
            reasonString = @"NEProviderStopReasonProviderDisabled The provider was disabled. ";
            break;
        case NEProviderStopReasonAuthenticationCanceled:
            reasonString = @"NEProviderStopReasonAuthenticationCanceled The authentication process was cancelled. ";
            break;
        case NEProviderStopReasonConfigurationFailed:
            reasonString = @"NEProviderStopReasonConfigurationFailed The provider could not be configured. ";
            break;
        case NEProviderStopReasonIdleTimeout:
            reasonString = @"NEProviderStopReasonIdleTimeout The provider was idle for too long. ";
            break;
        case NEProviderStopReasonConfigurationDisabled:
            reasonString = @"NEProviderStopReasonConfigurationDisabled The associated configuration was disabled. ";
            break;
        case NEProviderStopReasonConfigurationRemoved:
            reasonString = @"NEProviderStopReasonConfigurationRemoved The associated configuration was deleted. ";
            break;
        case NEProviderStopReasonSuperceded:
            reasonString = @"NEProviderStopReasonSuperceded A high-priority configuration was started. ";
            break;
        case NEProviderStopReasonUserLogout:
            reasonString = @"NEProviderStopReasonUserLogout The user logged out. ";
            break;
        case NEProviderStopReasonUserSwitch:
            reasonString = @"NEProviderStopReasonUserSwitch The active user changed. ";
            break;
        case NEProviderStopReasonConnectionFailed:
            reasonString = @"NEProviderStopReasonConnectionFailed Failed to establish connection. ";
            break;
            
        default:
            reasonString = @"Unknown reason. ";
            
    }
    DDLogInfo(@"(PacketTunnelProvider) Stop Tunnel Reason String:\n%@", reasonString);
    
    [_reachabilityHandler stopNotifier];
    
    pendingStartCompletion = nil;
    pendingStopCompletion = completionHandler;
    
    [self logNetworkInterfaces];
    
    [_connectionHandler closeAllConnections:^{
        pendingStartCompletion = nil;
        pendingStopCompletion();
        pendingStopCompletion = nil;
        
        DDLogInfo(@"(PacketTunnelProvider) Stop completion performed.");
    }];
}

- (void)handleAppMessage:(NSData *)messageData completionHandler:(void (^)(NSData *))completionHandler
{
    DDLogInfo(@"(PacketTunnelProvider) Handle Message Event");
    
    @synchronized (_connectionHandler) {
        
        switch ([APSharedResources host2tunnelMessageType:messageData]) {
            case APHTMLoggingEnabled:
                //Log enabled
                [_connectionHandler setDnsActivityLoggingEnabled:YES];
                DDLogInfo(@"(PacketTunnelProvider) Handled LoggingEnabled Message Event");
                break;
                
            case APHTMLoggingDisabled:
                //Log disabled
                [_connectionHandler setDnsActivityLoggingEnabled:NO];
                DDLogInfo(@"(PacketTunnelProvider) Handled LoggingDisabled Message Event");
                break;
                
            case APHTMLSystemWideDomainListReload:
                
                DDLogInfo(@"(PacketTunnelProvider) Domains lists changed. Reconnecting..");
                [self stopVPN];

                break;
                
            default:
                break;
        }
    }
}

- (void)sleepWithCompletionHandler:(void (^)(void))completionHandler
{
	// Add code here to get ready to sleep.
    DDLogInfo(@"(PacketTunnelProvider) Sleep Event");
	completionHandler();
    [self logNetworkInterfaces];
}

- (void)wake
{
	// Add code here to wake up.
    DDLogInfo(@"(PacketTunnelProvider) Wake Event");
    [self logNetworkInterfaces];
}

/////////////////////////////////////////////////////////////////////
#pragma mark Properties and public methods

- (APDnsServerObject *)currentDnsServer {
    
    return _currentServer;
}

- (BOOL)localFiltering {
    
    return _localFiltering;
}

- (BOOL)isRemoteServer {

    return _isRemoteServer;
}

- (void)getDNSServersIpv4: (NSArray <NSString *> **) ipv4DNSServers ipv6: (NSArray <NSString *> **) ipv6DNSServers {
  
    NSMutableArray *ipv4s = [NSMutableArray array];
    NSMutableArray *ipv6s = [NSMutableArray array];
    
    @autoreleasepool {
        
        res_state res = malloc(sizeof(struct __res_state));
        int result = res_ninit(res);
        if (result == 0) {
            union res_9_sockaddr_union *addr_union = malloc(res->nscount * sizeof(union res_9_sockaddr_union));
            res_getservers(res, addr_union, res->nscount);
            
            const char *str;
            for (int i = 0; i < res->nscount; i++) {
                if (addr_union[i].sin.sin_family == AF_INET) {
                    char ip[INET_ADDRSTRLEN];
                    str = inet_ntop(AF_INET, &(addr_union[i].sin.sin_addr), ip, INET_ADDRSTRLEN);
                    if (str) {
                        [ipv4s addObject:[NSString stringWithUTF8String:str]];
                    }
                } else if (addr_union[i].sin6.sin6_family == AF_INET6) {
                    char ip[INET6_ADDRSTRLEN];
                    str = inet_ntop(AF_INET6, &(addr_union[i].sin6.sin6_addr), ip, INET6_ADDRSTRLEN);
                    if (str) {
                        [ipv6s addObject:[NSString stringWithUTF8String:str]];
                    }
                } else {
                    str = NULL;
                }
                
                
            }
        }
        res_nclose(res);
        free(res);
    }
    
    *ipv4DNSServers = [ipv4s copy];
    *ipv6DNSServers = [ipv6s copy];
    
    return;
}

/////////////////////////////////////////////////////////////////////
#pragma mark Helper methods (private)

- (void)stopVPN {
    
    
    DDLogInfo(@"(PacketTunnelProvider) Stop VPN.");
    
    [self logNetworkInterfaces];

    [_reachabilityHandler stopNotifier];

    self.reasserting = YES;
    [self cancelTunnelWithError:nil];

}

- (void)reachNotify:(NSNotification *)note {
    
    DDLogInfo(@"(PacketTunnelProvider) reachability Notify");
    [self stopVPN];
}

- (void)reloadWhitelistBlacklistDomain {
    
    if (_localFiltering == NO) {
        
        [_connectionHandler setWhitelistFilter:nil];
        [_connectionHandler setBlacklistFilter:nil];
        
        DDLogInfo(@"(PacketTunnelProvider) System-Wide Filtering rules set to nil.");

        return;
    }
    
    @autoreleasepool {

        AERDomainFilter *wRules = [AERDomainFilter filter];
        AERDomainFilter *bRules = [AERDomainFilter filter];

        NSArray *rules;
        @autoreleasepool {
            
            // Init database and get rules
            NSURL *dbURL = [[AESharedResources sharedResuorcesURL] URLByAppendingPathComponent:AE_PRODUCTION_DB];
            
            [[ASDatabase singleton] initDbWithURL:dbURL upgradeDefaultDb:NO];
            NSError *error = [[ASDatabase singleton] error];
            if (!error) {
                
                AESAntibanner *antibanner = [[AEService new] antibanner];
                rules = [antibanner rulesForFilter:@(ASDF_SIMPL_DOMAINNAMES_FILTER_ID)];
                
                DDLogInfo(@"(PacketTunnelProvider) Count of rules, which was loaded from simple domain names filter: %lu.", rules.count);
            }
            
            [ASDatabase destroySingleton];
            //--------------------------
            if (rules.count == 0 && _isRemoteServer == NO) {
                
                DDLogError(@"(PacketTunnelProvider) We switch filtration to default remote server.");
                @autoreleasepool {
                    _currentServer = APVPNManager.predefinedDnsServers[APVPN_MANAGER_DEFAULT_REMOTE_DNS_SERVER_INDEX];
                    _isRemoteServer = YES;
                }
            }
        }
        
        @autoreleasepool {
            
            AERDomainFilterRule *rule;
            for (ASDFilterRule *item in rules) {
                
                rule = [AERDomainFilterRule rule:item.ruleText];
                
                if (rule.whiteListRule) {
                    [wRules addRule:rule];
                }
                else {
                    
                    [bRules addRule:rule];
                }
            }
        }

        DDLogInfo(@"(PacketTunnelProvider) Loaded whitelist rules: %lu, blacklist rules: %lu.", wRules.rulesCount, bRules.rulesCount);
        
        @autoreleasepool {
            NSArray *domainList = APSharedResources.whitelistDomains;
            NSUInteger counter = 0;
            for (NSString *item in domainList) {
                
                NSString *ruleText = [[[[APWhitelistDomainObject alloc] initWithDomain:item] rule] ruleText];
                if (ruleText) {
                    
                    [wRules addRule:[AERDomainFilterRule rule:ruleText]];
                    counter++;
                }
            }
            DDLogInfo(@"(PacketTunnelProvider) User whitelist rules: %lu", counter);
        }
        
        [_connectionHandler setWhitelistFilter:wRules];
        
        @autoreleasepool {
            NSArray *domainList = APSharedResources.blacklistDomains;
            NSUInteger counter = 0;
            for (NSString *item in domainList) {
                
                NSString *ruleText = [[[[AEBlacklistDomainObject alloc] initWithDomain:item] rule] ruleText];
                if (ruleText) {
                    
                    [bRules addRule:[AERDomainFilterRule rule:ruleText]];
                    counter++;
                }
            }
            DDLogInfo(@"(PacketTunnelProvider) User blacklist rules: %lu", counter);
        }
        
        [_connectionHandler setBlacklistFilter:bRules];
    }
}

- (NEPacketTunnelNetworkSettings *)createTunnelSettings {

    NEPacketTunnelNetworkSettings *settings = [[NEPacketTunnelNetworkSettings alloc] initWithTunnelRemoteAddress:V_REMOTE_ADDRESS];
    
    // DNS
    
    NSMutableArray *dnsAddresses = [NSMutableArray arrayWithCapacity:2];
    NSArray *deviceIpv4DnsServers;
    NSArray *deviceIpv6DnsServers;
    
    [self getDNSServersIpv4:&deviceIpv4DnsServers ipv6:&deviceIpv6DnsServers];
    NSMutableArray *allDeviceDnsServers = [NSMutableArray new];
    [allDeviceDnsServers addObjectsFromArray:deviceIpv4DnsServers];
    [allDeviceDnsServers addObjectsFromArray:deviceIpv6DnsServers];
    
    if (_isRemoteServer) {
        
        [dnsAddresses addObjectsFromArray:_currentServer.ipv4Addresses];
        [dnsAddresses addObjectsFromArray:_currentServer.ipv6Addresses];
        
    }
    else {
        [dnsAddresses addObject:V_INTERFACE_IPV4_ADDRESS];
        [dnsAddresses addObject:V_INTERFACE_IPV6_ADDRESS];
    }
    
    [dnsAddresses addObjectsFromArray:allDeviceDnsServers];
    
    [_connectionHandler setDeviceDnsAddresses:allDeviceDnsServers adguardDnsAddresses:dnsAddresses];
    
    NEDNSSettings *dns = [[NEDNSSettings alloc] initWithServers:dnsAddresses];
    dns.matchDomains = @[ @"" ];
    
    settings.DNSSettings = dns;
    
    
    // IPv4
    NEIPv4Settings *ipv4 = [[NEIPv4Settings alloc]
                            initWithAddresses:@[V_INTERFACE_IPV4_ADDRESS]
                            subnetMasks:@[V_INTERFACE_IPV4_MASK]];
    
    NSMutableArray *ipv4routes = [NSMutableArray new];
    
    if (_isRemoteServer) {
        
        // route for ipv4, which includes dns addresses
        for (NSString *item in _currentServer.ipv4Addresses) {
            [ipv4routes addObject:[[NEIPv4Route alloc]
                                initWithDestinationAddress:item
                                subnetMask:V_INTERFACE_IPV4_FULL_MASK]];
        }
    }
    else {
        // route for ipv4, which includes FAKE dns addresses
        [ipv4routes addObject:[[NEIPv4Route alloc]
                            initWithDestinationAddress:V_INTERFACE_IPV4_ADDRESS
                            subnetMask:V_INTERFACE_IPV4_FULL_MASK]];
    }
    
    // add primary DNS ips to routes
    for(NSString* ipv4Dns in deviceIpv4DnsServers) {
        [ipv4routes addObject:[[NEIPv4Route alloc]
                           initWithDestinationAddress:ipv4Dns
                           subnetMask:V_INTERFACE_IPV4_FULL_MASK]];
    }
    
    ipv4.includedRoutes = ipv4routes;
    ipv4.excludedRoutes = @[[NEIPv4Route defaultRoute]];
    
    settings.IPv4Settings = ipv4;
    
    // IPv6
    if ([self isIpv6Available]) {
        
        NEIPv6Settings *ipv6 = [[NEIPv6Settings alloc]
                                initWithAddresses:@[V_INTERFACE_IPV6_ADDRESS]
                                networkPrefixLengths:@[V_INTERFACE_IPV6_MASK]];
        
        NSMutableArray *ipv6routes = [NSMutableArray new];
        
        if (_isRemoteServer) {
            
            // route for ipv6, which includes dns addresses
            for (NSString *item in _currentServer.ipv6Addresses) {
                [ipv6routes addObject:[[NEIPv6Route alloc]
                                    initWithDestinationAddress:item
                                    networkPrefixLength:V_INTERFACE_IPV6_FULL_MASK]];
            }
            
        }
        else {
            // route for ipv6, which includes FAKE dns addresses
            [ipv6routes addObject:[[NEIPv6Route alloc]
                                initWithDestinationAddress:V_INTERFACE_IPV6_ADDRESS
                                networkPrefixLength:V_INTERFACE_IPV6_FULL_MASK]];
        }
        
        // add primary DNS ips to routes
        for(NSString* ipv6Dns in deviceIpv6DnsServers) {
            [ipv6routes addObject:[[NEIPv6Route alloc]
                               initWithDestinationAddress:ipv6Dns
                               networkPrefixLength:V_INTERFACE_IPV6_FULL_MASK]];
        }
        
        // add mapped ipv4 routes
        for(NEIPv4Route* ipv4Route in ipv4routes) {
            NSString* mappedIpv4 = [self ipv6MappedFromIpv4: ipv4Route.destinationAddress];
            
            [ipv6routes addObject:[[NEIPv6Route alloc]
                                   initWithDestinationAddress:mappedIpv4
                                   networkPrefixLength:V_INTERFACE_IPV6_FULL_MASK]];
        }
        
        ipv6.includedRoutes = ipv6routes;
        ipv6.excludedRoutes = @[[NEIPv6Route defaultRoute]];
        
        settings.IPv6Settings = ipv6;
    }
    
    return settings;
}

- (BOOL) isIpv6Available {
    BOOL ipv6Available = NO;
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        addr = interfaces;
        
        while(addr != NULL) {
            int32_t flags = addr->ifa_flags;
            
            // Check for running IPv4, IPv6 interfaces. Skip the loopback interface.
            if ((flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING)) {
                
                NSString* address;
                if(addr->ifa_addr->sa_family == AF_INET6){
                    char ip[INET6_ADDRSTRLEN];
                    const char *str = inet_ntop(AF_INET6, &(((struct sockaddr_in6 *)addr->ifa_addr)->sin6_addr), ip, INET6_ADDRSTRLEN);
                    
                    address = [NSString stringWithUTF8String:str];
                    NSArray* addressComponents = [address componentsSeparatedByString:@":"];
                    if(![addressComponents.firstObject isEqualToString:@"fe80"]){ // fe80 prefix in link-local ip
                        ipv6Available = YES;
                        break;
                    }
                }
            }
            
            addr = addr->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return ipv6Available;
}

- (void)logNetworkInterfaces {
    
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        NSMutableString* log = [NSMutableString new];
        addr = interfaces;
        
        while(addr != NULL) {
            int32_t flags = addr->ifa_flags;
            
            // Check for running IPv4, IPv6 interfaces. Skip the loopback interface.
            if ((flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING)) {
                
                NSString* address;
                if(addr->ifa_addr->sa_family == AF_INET){
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)addr->ifa_addr)->sin_addr)];
                    
                    NSString* interfaceString = [NSString stringWithFormat:@"%@/ipv4:%@", [NSString stringWithUTF8String:addr->ifa_name], address];
                    [log appendFormat:@"%@\n", interfaceString];
                }
                else if(addr->ifa_addr->sa_family == AF_INET6){
                    char ip[INET6_ADDRSTRLEN];
                    const char *str = inet_ntop(AF_INET6, &(((struct sockaddr_in6 *)addr->ifa_addr)->sin6_addr), ip, INET6_ADDRSTRLEN);
                    
                    address = [NSString stringWithUTF8String:str];
                    
                    NSString* interfaceString = [NSString stringWithFormat:@"%@/ipv6:%@", [NSString stringWithUTF8String:addr->ifa_name], address];
                    [log appendFormat:@"%@\n", interfaceString];
                }
            }
            
            addr = addr->ifa_next;
        }
        
        DDLogInfo(@"(PacketTunnelProvider) Available network interfaces:\n%@", log);
    }
    // Free memory
    freeifaddrs(interfaces);
}

- (NSString*) ipv6MappedFromIpv4:(NSString*)ipv4Address {
    return [@"::FFFF:" stringByAppendingString:ipv4Address];
}

@end
