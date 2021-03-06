//
// MixModule.swift
//
// TigaseSwift
// Copyright (C) 2020 "Tigase, Inc." <office@tigase.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. Look for COPYING file in the top folder.
// If not, see http://www.gnu.org/licenses/.
//

import Foundation

extension XmppModuleIdentifier {
    public static var mix: XmppModuleIdentifier<MixModule> {
        return MixModule.IDENTIFIER;
    }
}

open class MixModule: XmppModuleBase, XmppModule, EventHandler, RosterAnnotationAwareProtocol {
    func prepareRosterGetRequest(queryElem el: Element) {
        el.addChild(Element(name: "annotate", xmlns: "urn:xmpp:mix:roster:0"));
    }
    
    func process(rosterItemElem el: Element) -> RosterItemAnnotation? {
        guard let channelEl = el.findChild(name: "channel", xmlns: "urn:xmpp:mix:roster:0"), let id = channelEl.getAttribute("participant-id") else {
            return nil;
        }
        return RosterItemAnnotation(type: "mix", values: ["participant-id": id]);
    }
    
    public static let CORE_XMLNS = "urn:xmpp:mix:core:1";
    public static let IDENTIFIER = XmppModuleIdentifier<MixModule>();
    public static let ID = "mix";
    public static let PAM2_XMLNS = "urn:xmpp:mix:pam:2";
    
    public let criteria: Criteria = Criteria.or(
        Criteria.name("message", types: [.groupchat], containsAttribute: "from").add(Criteria.name("mix", xmlns: MixModule.CORE_XMLNS)),
        Criteria.name("message", types: [.error], containsAttribute: "from")
    );
    
    public let features: [String] = [CORE_XMLNS];

    public override weak var context: Context? {
        didSet {
            oldValue?.eventBus.unregister(handler: self, for: [RosterModule.ItemUpdatedEvent.TYPE, PubSubModule.NotificationReceivedEvent.TYPE, SessionEstablishmentModule.SessionEstablishmentSuccessEvent.TYPE, StreamManagementModule.ResumedEvent.TYPE, SessionObject.ClearedEvent.TYPE, DiscoveryModule.AccountFeaturesReceivedEvent.TYPE]);
            oldValue?.unregister(lifecycleAware: channelManager);
            context?.eventBus.register(handler: self, for: [RosterModule.ItemUpdatedEvent.TYPE, PubSubModule.NotificationReceivedEvent.TYPE, SessionEstablishmentModule.SessionEstablishmentSuccessEvent.TYPE, StreamManagementModule.ResumedEvent.TYPE, SessionObject.ClearedEvent.TYPE, DiscoveryModule.AccountFeaturesReceivedEvent.TYPE]);
            context?.register(lifecycleAware: channelManager);
            if let context = context {
                discoModule = context.modulesManager.module(.disco);
                mamModule = context.modulesManager.module(.mam);
                pubsubModule = context.modulesManager.module(.pubsub);
                avatarModule = context.modulesManager.module(.pepUserAvatar);
                presenceModule = context.modulesManager.module(.presence);
                rosterModule = context.modulesManager.module(.roster);
            } else {
                discoModule = nil;
                mamModule = nil;
                pubsubModule = nil;
                avatarModule = nil;
                presenceModule = nil;
                rosterModule = nil;
            }
        }
    }

    private var discoModule: DiscoveryModule!;
    private var mamModule: MessageArchiveManagementModule!;
    private var pubsubModule: PubSubModule!;
    private var avatarModule: PEPUserAvatarModule!;
    private var presenceModule: PresenceModule!;
    private var rosterModule: RosterModule!;

    public let channelManager: ChannelManager;
    
    public var isPAM2SupportAvailable: Bool {
        let accountFeatures: [String] = discoModule?.accountDiscoResult?.features ?? [];
        return accountFeatures.contains(MixModule.PAM2_XMLNS);
    }
    
    public var localMAMStoresPubSubEvents: Bool {
        return isPAM2SupportAvailable && false;
    }
    
    public enum AutomaticRetriveActions {
        case participants
        case info
        case avatar
        case affiliations
    }
    
    public var automaticRetrieve: Set<AutomaticRetriveActions> = [.participants,.info,.avatar,.affiliations];
    
    public init(channelManager: ChannelManager) {
        self.channelManager = channelManager;
    }
    
    open func create(channel: String?, at componentJid: BareJID, completionHandler: @escaping (Result<BareJID,XMPPError>)->Void) {
        guard componentJid.localPart == nil else {
            completionHandler(.failure(.bad_request("MIX component JID cannot have local part set!")));
            return;
        }
        
        let iq = Iq();
        iq.to = JID(componentJid);
        iq.type = .set;
        let createEl = Element(name: "create", xmlns: MixModule.CORE_XMLNS);
        if channel != nil {
            createEl.setAttribute("channel", value: channel);
        }
        iq.addChild(createEl);
        write(iq, completionHandler: { result in
            switch result {
            case .success(let response):
                if let channel = response.findChild(name: "create", xmlns: MixModule.CORE_XMLNS)?.getAttribute("channel") {
                    completionHandler(.success(BareJID(localPart: channel, domain: componentJid.domain)));
                } else {
                    completionHandler(.failure(.undefined_condition));
                }
            case .failure(let error):
                completionHandler(.failure(error));
            }
        });
    }
        
    open func destroy(channel channelJid: BareJID, completionHandler: @escaping (Result<Void,XMPPError>)->Void) {
        guard channelJid.localPart != nil else {
            completionHandler(.failure(.bad_request("Channel JID must have a local part!")));
            return;
        }
        guard let context = self.context else {
            completionHandler(.failure(.remote_server_timeout));
            return;
        }
        
        let iq = Iq();
        iq.to = JID(channelJid.domain);
        iq.type = .set;
        let destroyEl = Element(name: "destroy", xmlns: MixModule.CORE_XMLNS);
        destroyEl.setAttribute("channel", value: channelJid.localPart);
        iq.addChild(destroyEl);
        write(iq, completionHandler: { result in
            switch result {
            case .success(_):
                if let channel = self.channelManager.channel(for: context, with: channelJid) {
                    _  = self.channelManager.close(channel: channel);
                }
                self.rosterModule?.store.remove(jid: JID(channelJid), completionHandler: nil);
                completionHandler(.success(Void()));
            case .failure(let error):
                completionHandler(.failure(error));
            }
        });
    }
    
    open func join(channel channelJid: BareJID, withNick nick: String?, subscribeNodes nodes: [String] = ["urn:xmpp:mix:nodes:messages", "urn:xmpp:mix:nodes:participants", "urn:xmpp:mix:nodes:info", "urn:xmpp:avatar:metadata"], presenceSubscription: Bool = true, invitation: MixInvitation? = nil, messageSyncLimit: Int = 100, completionHandler: @escaping (Result<Iq,XMPPError>) -> Void) {
        guard let context = self.context else {
            completionHandler(.failure(.remote_server_timeout));
            return;
        }
        if isPAM2SupportAvailable {
            let iq = Iq();
            iq.to = JID(context.userBareJid);
            iq.type = .set;
            let clientJoin = Element(name: "client-join", xmlns: MixModule.PAM2_XMLNS);
            clientJoin.setAttribute("channel", value: channelJid.stringValue);
            clientJoin.addChild(createJoinEl(withNick: nick, withNodes: nodes, invitation: invitation));
            iq.addChild(clientJoin);
            
            write(iq, completionHandler: { result in
                switch result {
                case .success(let response):
                    if let joinEl = response.findChild(name: "client-join", xmlns: MixModule.PAM2_XMLNS)?.findChild(name: "join", xmlns: MixModule.CORE_XMLNS) {
                        if let resultJid = joinEl.getAttribute("jid"), let idx = resultJid.firstIndex(of: "#") {
                            let participantId = String(resultJid[resultJid.startIndex..<idx]);
                            let jid = BareJID(String(resultJid[resultJid.index(after: idx)..<resultJid.endIndex]));
                            self.channelJoined(channelJid: jid, participantId: participantId, nick: joinEl.findChild(name: "nick")?.value);
                            
                            self.retrieveHistory(fromChannel: channelJid, max: messageSyncLimit);
                            if presenceSubscription {
                                self.presenceModule?.subscribed(by: JID(channelJid));
                                self.presenceModule?.subscribe(to: JID(channelJid));
                            }
                        } else if let participantId = joinEl.getAttribute("id") {
                            self.channelJoined(channelJid: channelJid, participantId: participantId, nick: joinEl.findChild(name: "nick")?.value);
                            self.retrieveHistory(fromChannel: channelJid, max: messageSyncLimit);
                            if presenceSubscription {
                                self.presenceModule?.subscribed(by: JID(channelJid));
                                self.presenceModule?.subscribe(to: JID(channelJid));
                            }
                        }
                    }
                default:
                    break;
                }
                completionHandler(result);
            });
        } else {
            let iq = Iq();
            iq.to = JID(channelJid);
            iq.type = .set;
            iq.addChild(createJoinEl(withNick: nick, withNodes: nodes, invitation: invitation));
            write(iq, completionHandler: { result in
                switch result {
                case .success(let response):
                    if let joinEl = response.findChild(name: "join", xmlns: MixModule.CORE_XMLNS), let participantId = joinEl.getAttribute("id") {
                        self.retrieveHistory(fromChannel: channelJid, max: messageSyncLimit);
                        self.channelJoined(channelJid: channelJid, participantId: participantId, nick: joinEl.findChild(name: "nick")?.value);
                    }
                default:
                    break;
                }
                completionHandler(result);
            });
        }
    }
    
    open func leave(channel: ChannelProtocol, completionHandler: @escaping (Result<Iq,XMPPError>)->Void) {
        guard let context = context else {
            completionHandler(.failure(.remote_server_timeout));
            return;
        }
        if isPAM2SupportAvailable {
            let iq = Iq();
            iq.to = JID(context.userBareJid);
            iq.type = .set;
            let clientLeave = Element(name: "client-leave", xmlns: MixModule.PAM2_XMLNS);
            clientLeave.setAttribute("channel", value: channel.jid.stringValue);
            clientLeave.addChild(Element(name: "leave", xmlns: MixModule.CORE_XMLNS));
            iq.addChild(clientLeave);
            
            write(iq, completionHandler: { result in
                switch result {
                case .success(_):
                    self.channelLeft(channel: channel);
                default:
                    break;
                }
                completionHandler(result);
            });
        } else {
            let iq = Iq();
            iq.to = JID(channel.jid);
            iq.type = .set;
            iq.addChild(Element(name: "leave", xmlns: MixModule.CORE_XMLNS));
            write(iq, completionHandler: { result in
                switch result {
                case .success(_):
                    self.channelLeft(channel: channel);
                default:
                    break;
                }
                completionHandler(result);
            });
        }
    }
    
    open func channelJoined(channelJid: BareJID, participantId: String, nick: String?) {
        guard let context = self.context else {
            return;
        }
        switch self.channelManager.createChannel(for: context, with: channelJid, participantId: participantId, nick: nick, state: .joined) {
        case .created(let channel):
            if self.automaticRetrieve.contains(.participants) {
                retrieveParticipants(for: channel, completionHandler: nil);
            }
            retrieveInfo(for: channel.jid, completionHandler: nil);
            retrieveAffiliations(for: channel, completionHandler: nil);
            if self.automaticRetrieve.contains(.avatar) {
                retrieveAvatar(for: channel.jid, completionHandler: nil);
            }
        default:
            break;
        }
    }

    open func channelLeft(channel: ChannelProtocol) {
        _ = self.channelManager.close(channel: channel);
    }
    
    // we may want to add "status" to the channel, to know if we are in participants or not..
    
    open func createJoinEl(withNick nick: String?, withNodes nodes: [String], invitation: MixInvitation?) -> Element {
        let joinEl = Element(name: "join", xmlns: MixModule.CORE_XMLNS);
        joinEl.addChildren(nodes.map({ Element(name: "subscribe", attributes: ["node": $0]) }));
        if let nick = nick {
            joinEl.addChild(Element(name: "nick", cdata: nick));
        }
        if let invitation = invitation {
            joinEl.addChild(invitation.element());
        }
        return joinEl;
    }
    
    open func process(stanza: Stanza) throws {
        switch stanza {
        case let message as Message:
            // we have received groupchat message..
            guard let context = context, let channel = channelManager.channel(for: context, with: message.from!.bareJid) else {
                return;
            }
            self.fire(MessageReceivedEvent(context: context, message: message, channel: channel, nickname: message.mix?.nickname, senderJid: message.mix?.jid, timestamp: message.delay?.stamp ?? Date()));
        default:
            break;
        }
    }
    
    open func retrieveAffiliations(for channel: ChannelProtocol, completionHandler: ((PermissionsResult)->Void)?) {
        pubsubModule.retrieveOwnAffiliations(from: channel.jid, for: nil, completionHandler: { result in
            switch result {
            case .success(let affiliations):
                let values = Dictionary(affiliations.map({ ($0.node, $0.affiliation) }), uniquingKeysWith: { (first, _) in first });
                var permissions: Set<ChannelPermission> = [];
                switch values["urn:xmpp:mix:nodes:info"] ?? .none {
                case .owner, .publisher:
                    permissions.insert(.changeInfo);
                default:
                    break;
                }
                switch values["urn:xmpp:mix:nodes:config"] ?? .none {
                case .owner, .publisher:
                    permissions.insert((.changeConfig));
                default:
                    break;
                }
                switch values["urn:xmpp:avatar:metadata"] ?? .none {
                case .owner, .publisher:
                    permissions.insert((.changeAvatar));
                default:
                    break;
                }
                channel.update(permissions: permissions);
            case .failure(_):
                channel.update(permissions: []);
            }
            if let context = self.context {
                self.fire(ChannelPermissionsChangedEvent(context: context, channel: channel));
            }
        })
    }
    
    open func retrieveParticipants(for channel: ChannelProtocol, completionHandler: ((ParticipantsResult)->Void)?) {
        pubsubModule.retrieveItems(from: channel.jid, for: "urn:xmpp:mix:nodes:participants", completionHandler: { result in
            switch result {
            case .success(let items):
                let participants = items.items.map({ (item) -> MixParticipant? in
                    return MixParticipant(from: item);
                }).filter({ $0 != nil }).map({ $0! });
                let oldParticipants = channel.participants;
                let left = oldParticipants.filter({ old in !participants.contains(where: { new in new.id == old.id})});
                if let ownParticipant = participants.first(where: { (participant) -> Bool in
                    return participant.id == channel.participantId
                }) {
                    channel.update(ownNickname: ownParticipant.nickname);
                }
                channel.set(participants: participants);
                if let context = self.context {
                    self.fire(ParticipantsChangedEvent(context: context, channel: channel, joined: participants, left: left));
                }
                completionHandler?(.success(participants));
            case .failure(let pubsubError):
                completionHandler?(.failure(pubsubError.error));
            }
        })
    }
    
    open func publishInfo(for channelJid: BareJID, info: ChannelInfo, completionHandler: ((Result<Void,XMPPError>)->Void)?) {
        pubsubModule.publishItem(at: channelJid, to: "urn:xmpp:mix:nodes:info", payload: info.form().submitableElement(type: .result), completionHandler: { response in
            switch response {
            case .success(_):
                completionHandler?(.success(Void()));
            case .failure(let error):
                completionHandler?(.failure(error.error));
            }
        });
    }
    
    open func retrieveInfo(for channelJid: BareJID, completionHandler: ((Result<ChannelInfo,XMPPError>)->Void)?) {
        pubsubModule.retrieveItems(from: channelJid, for: "urn:xmpp:mix:nodes:info", completionHandler: { result in
            switch result {
            case .success(let items):
                guard let item = items.items.sorted(by: { (i1, i2) in return i1.id > i2.id }).first else {
                    completionHandler?(.failure(.item_not_found));
                    return;
                }
                guard let context = self.context, let info = ChannelInfo(form: JabberDataElement(from: item.payload)) else {
                    completionHandler?(.failure(.undefined_condition));
                    return;
                }
                if let channel = self.channelManager.channel(for: context, with: channelJid) {
                    channel.update(info: info);
                }
                completionHandler?(.success(info));
            case .failure(let pubsubError):
                completionHandler?(.failure(pubsubError.error));
            }
        });
    }

    open func retrieveConfig(for channelJid: BareJID, completionHandler: @escaping (Result<JabberDataElement,XMPPError>)->Void) {
        pubsubModule.retrieveItems(from: channelJid, for: "urn:xmpp:mix:nodes:config", limit: .lastItems(1), completionHandler: { result in
            switch result {
            case .success(let items):
                guard let item = items.items.first else {
                    completionHandler(.failure(.item_not_found));
                    return;
                }
                guard let config = JabberDataElement(from: item.payload) else {
                    completionHandler(.failure(.undefined_condition));
                    return;
                }
                completionHandler(.success(config));
            case .failure(let pubsubError):
                completionHandler(.failure(pubsubError.error));
            }
        });
    }
    
    open func updateConfig(for channelJid: BareJID, config: JabberDataElement, completionHandler: @escaping (Result<Void,XMPPError>)->Void) {
        pubsubModule.publishItem(at: channelJid, to: "urn:xmpp:mix:nodes:config", payload: config.submitableElement(type: .submit), completionHandler: { response in
            switch response {
            case .success(_):
                completionHandler(.success(Void()));
            case .failure(let pubsubError):
                completionHandler(.failure(pubsubError.error));
            }
        });
    }
    
    open func allowAccess(to channelJid: BareJID, for jid: BareJID, value: Bool = true, completionHandler: @escaping (Result<Void,XMPPError>)->Void) {
        publishAccessRule(to: channelJid, for: jid, rule: .allow, value: value, completionHandler: completionHandler);
    }
    
    open func denyAccess(to channelJid: BareJID, for jid: BareJID, value: Bool = true, completionHandler: @escaping (Result<Void,XMPPError>)->Void) {
        publishAccessRule(to: channelJid, for: jid, rule: .deny, value: value, completionHandler: { result in
            switch result {
            case.success(let r):
                completionHandler(.success(r));
            case .failure(let errorCondition):
                guard errorCondition == .item_not_found, let pubsubModule = self.pubsubModule else {
                    completionHandler(.failure(errorCondition));
                    return;
                }
                pubsubModule.createNode(at: channelJid, node: AccessRule.deny.node, completionHandler: { result in
                    switch result {
                    case .success(_):
                        self.publishAccessRule(to: channelJid, for: jid, rule: .deny, value: value, completionHandler: completionHandler);
                    case .failure(let pubsubError):
                        completionHandler(.failure(pubsubError.error));
                    }
                })
            }
        });
    }
    
    open func createInvitation(_ invitation: MixInvitation, message body: String?) -> Message {
        let message = Message();
        message.type = .chat;
        message.id = UUID().uuidString;
        message.to = JID(invitation.invitee);
        message.mixInvitation = invitation;
        message.body = body;
        return message;
    }
    
    private func publishAccessRule(to channelJid: BareJID, for jid: BareJID, rule: AccessRule, value: Bool, completionHandler: @escaping (Result<Void,XMPPError>)->Void) {
        if value {
            pubsubModule.publishItem(at: channelJid, to: rule.node, itemId: jid.stringValue, payload: nil, completionHandler: { result in
                switch result {
                case .success(_):
                    completionHandler(.success(Void()));
                case .failure(let pubsubError):
                    completionHandler(.failure(pubsubError.error));
                }
            })
        } else {
            pubsubModule.retractItem(at: channelJid, from: rule.node, itemId: jid.stringValue, completionHandler: { result in
                switch result {
                case .success(_):
                    completionHandler(.success(Void()));
                case .failure(let pubsubError):
                    completionHandler(.failure(pubsubError.error));
                }
            })
        }
    }
    
    open func changeAccessPolicy(of channelJid: BareJID, isPrivate: Bool, completionHandler: @escaping (Result<Void,XMPPError>)->Void) {
        guard let jid = context?.userBareJid else {
            completionHandler(.failure(.remote_server_timeout));
            return;
        }
        if isPrivate {
            pubsubModule.createNode(at: channelJid, node: AccessRule.allow.node, completionHandler: { result in
                switch result {
                case .success(_):
                    self.allowAccess(to: channelJid, for: jid, completionHandler: completionHandler);
                case .failure(let pubsubError):
                    completionHandler(.failure(pubsubError.error));
                }
            })
        } else {
            pubsubModule.deleteNode(from: channelJid, node: AccessRule.allow.node, completionHandler: { result in
                switch result {
                case .success(_):
                    completionHandler(.success(Void()));
                case .failure(let pubsubError):
                    completionHandler(.failure(pubsubError.error));
                }
            })
        }
    }
    
    open func checkAccessPolicy(of channelJid: BareJID, completionHandler: @escaping (Result<Bool,XMPPError>)->Void) {
        self.retrieveAccessRules(for: channelJid, rule: .allow, completionHandler: { result in
            switch result {
            case .success(_):
                completionHandler(.success(true));
            case .failure(let errorCondition):
                if errorCondition == .item_not_found {
                    completionHandler(.success(false));
                } else {
                    completionHandler(.failure(errorCondition));
                }
            }
        });
    }
    
    open func retrieveAllowed(for channelJid: BareJID, completionHandler: @escaping (Result<[BareJID],XMPPError>)->Void) {
        self.retrieveAccessRules(for: channelJid, rule: .allow, completionHandler: completionHandler);
    }
    
    open func retrieveBanned(for channelJid: BareJID, completionHandler: @escaping (Result<[BareJID],XMPPError>)->Void) {
        self.retrieveAccessRules(for: channelJid, rule: .deny, completionHandler: completionHandler);
    }
    
    private func retrieveAccessRules(for channelJid: BareJID, rule: AccessRule, completionHandler: @escaping (Result<[BareJID],XMPPError>)->Void) {
        pubsubModule.retrieveItems(from: channelJid, for: rule.node, completionHandler: { result in
            switch result {
            case .success(let items):
                completionHandler(.success(items.items.map({ BareJID($0.id) })));
            case .failure(let pubsubError):
                completionHandler(.failure(pubsubError.error));
            }
        })
    }
        
    public enum AccessRule {
        case allow
        case deny
        
        var node: String {
            switch self {
            case .allow:
                return "urn:xmpp:mix:nodes:allowed";
            case .deny:
                return "urn:xmpp:mix:nodes:banned";
            }
        }
    }
    
    open func handle(event: Event) {
        switch event {
        case let e as RosterModule.ItemUpdatedEvent:
            // react on add/remove channel in the roster
            guard isPAM2SupportAvailable, let ri = e.rosterItem else {
                return;
            }
            
            switch e.action {
            case .removed:
                guard let channel = channelManager.channel(for: e.context, with: ri.jid.bareJid) else {
                    return;
                }
                self.channelLeft(channel: channel);
            default:
                guard let annotation = ri.annotations.first(where: { item -> Bool in
                    return item.type == "mix";
                }), let participantId = annotation.values["participant-id"] else {
                    return;
                }
                
                self.channelJoined(channelJid: ri.jid.bareJid, participantId: participantId, nick: nil);
                if !isPAM2SupportAvailable {
                    retrieveHistory(fromChannel: ri.jid.bareJid, max: 100);
                }
            }
            break;
        case let e as PubSubModule.NotificationReceivedEvent:
            guard let from = e.message.from?.bareJid, let node = e.nodeName, let channel = channelManager.channel(for: e.context, with: from) else {
                return;
            }

            switch node {
            case "urn:xmpp:mix:nodes:participants":
                switch e.itemType {
                case "item":
                    if let item = e.item, let participant = MixParticipant(from: item) {
                        if participant.id == channel.participantId {
                            channel.update(ownNickname: participant.nickname);
                        }
                        channel.update(participant: participant);
                        if let context = context {
                            self.fire(ParticipantsChangedEvent(context: context, channel: channel, joined: [participant]));
                        }
                    }
                case "retract":
                    if let id = e.itemId {
                        if channel.participantId == id {
                            channel.update(state: .left);
                            if let context = context {
                                self.fire(ChannelStateChangedEvent(context: context, channel: channel));
                            }
                        }
                        if let participant = channel.removeParticipant(withId: id), let context = context {
                            self.fire(ParticipantsChangedEvent(context: context, channel: channel, left: [participant]));
                        }
                    }
                default:
                    break;
                }
            case "urn:xmpp:mix:nodes:info":
                guard let info = ChannelInfo(form: JabberDataElement(from: e.payload)) else {
                    return;
                }
                channel.update(info: info);
            default:
                break;
            }
        case is SessionEstablishmentModule.SessionEstablishmentSuccessEvent, is StreamManagementModule.ResumedEvent:
            // we have reconnected, so lets update all channels statuses
            if let context = context {
                for channel in self.channelManager.channels(for: context) {
                    self.fire(ChannelStateChangedEvent(context: context, channel: channel));
                }
            }
        case is SessionObject.ClearedEvent:
            if let context = context {
                for channel in self.channelManager.channels(for: context) {
                    self.fire(ChannelStateChangedEvent(context: context, channel: channel));
                }
            }
        case let e as DiscoveryModule.AccountFeaturesReceivedEvent:
            if !localMAMStoresPubSubEvents {
                if !isPAM2SupportAvailable {
                    for channel in self.channelManager.channels(for: e.context) {
                        if let lastMessageDate = (channel as? LastMessageTimestampAware)?.lastMessageTimestamp {
                            self.retrieveHistory(fromChannel: channel.jid, start: lastMessageDate, after: nil);
                        } else {
                            self.retrieveHistory(fromChannel: channel.jid, max: 100);
                        }
                    }
                }
                for channel in self.channelManager.channels(for: e.context) {
                    if self.automaticRetrieve.contains(.participants) {
                        retrieveParticipants(for: channel, completionHandler: nil);
                    }
                    if self.automaticRetrieve.contains(.info) {
                        retrieveInfo(for: channel.jid, completionHandler: nil);
                    }
                    if self.automaticRetrieve.contains(.affiliations) {
                        retrieveAffiliations(for: channel, completionHandler: nil);
                    }
                    if self.automaticRetrieve.contains(.avatar) {
                        retrieveAvatar(for: channel.jid, completionHandler: nil);
                    }
                }
            }
            if isPAM2SupportAvailable {
                let store = rosterModule.store;
                for jid in store.getJids() {
                    if let item = store.get(for: jid), let annotation = item.annotations.first(where: { item -> Bool in
                        return item.type == "mix";
                    }), let participantId = annotation.values["participant-id"] {
                        self.channelJoined(channelJid: item.jid.bareJid, participantId: participantId, nick: nil);
                    }
                }
            }
        default:
            break;
        }
    }
    
    // for initial retrieval after join..
    open func retrieveHistory(fromChannel jid: BareJID, max: Int) {
        self.retrieveHistory(fromChannel: jid, start: nil, rsm: RSM.Query(lastItems: max))
    }

    open func retrieveHistory(fromChannel jid: BareJID, start: Date, after: String?) {
        self.retrieveHistory(fromChannel: jid, start: start, rsm: RSM.Query(before: nil, after: after, max: 100));
    }

    open func retrieveHistory(fromChannel jid: BareJID, start: Date?, rsm: RSM.Query) {
        let queryId = UUID().uuidString;
        // should we query MIX messages node? or just MAM at MIX channel without a node?
        mamModule.queryItems(version: .MAM2, componentJid: JID(jid), node: "urn:xmpp:mix:nodes:messages", start: nil, queryId: queryId, rsm: rsm, completionHandler: { result in
            switch result {
            case .success(let queryResult):
                guard !queryResult.complete, let rsmQuery = queryResult.rsm?.next() else {
                    return;
                }
                self.retrieveHistory(fromChannel: jid, start: start, rsm: rsmQuery);
            case .failure(_):
                break;
            }
        });
    }
    
    open func retrieveAvatar(for jid: BareJID, completionHandler: ((Result<PEPUserAvatarModule.Info, XMPPError>)->Void)?) {
        avatarModule.retrieveAvatarMetadata(from: jid, itemId: nil, fireEvents: true, completionHandler: { result in
            completionHandler?(result);
        });
    }

    /// Event fired when received message in room
    open class MessageReceivedEvent: AbstractEvent {
        /// Identifier of event which should be used during registration of `EventHandler`
        public static let TYPE = MessageReceivedEvent();
        
        /// Received message
        public let message: Message!;
        /// Room which delivered message
        public let channel: ChannelProtocol!;
        /// Nickname of message sender
        public let nickname: String?;
        /// Sender real JID
        public let senderJid: BareJID?;
        /// Timestamp of message
        public let timestamp: Date!;
        
        init() {
            self.message = nil;
            self.channel = nil;
            self.nickname = nil;
            self.senderJid = nil;
            self.timestamp = nil;
            super.init(type: "MixModuleMessageReceivedEvent")
        }
        
        public init(context: Context, message: Message, channel: ChannelProtocol, nickname: String?, senderJid: BareJID?, timestamp: Date) {
            self.message = message;
            self.channel = channel;
            self.nickname = nickname;
            self.senderJid = senderJid;
            self.timestamp = timestamp;
            super.init(type: "MixModuleMessageReceivedEvent", context: context);
        }
        
    }

    open class ChannelStateChangedEvent: AbstractEvent {
        
        public static let TYPE = ChannelStateChangedEvent();

        public let channel: ChannelProtocol!;

        init() {
            self.channel = nil;
            super.init(type: "MixModuleChannelStateChangedEvent");
        }
        
        public init(context: Context, channel: ChannelProtocol) {
            self.channel = channel;
            super.init(type: "MixModuleChannelStateChangedEvent", context: context)
        }
    }
    
    open class ParticipantsChangedEvent: AbstractEvent {
        
        public static let TYPE = ParticipantsChangedEvent();

        public let channel: ChannelProtocol!;
        public let joined: [MixParticipant];
        public let left: [MixParticipant];
        
        init() {
            self.channel = nil;
            self.joined = [];
            self.left = [];
            super.init(type: "MixModuleParticipantChangedEvent")
        }
        
        public init(context: Context, channel: ChannelProtocol, joined: [MixParticipant] = [], left: [MixParticipant] = []) {
            self.channel = channel;
            self.joined = joined;
            self.left = left;
            super.init(type: "MixModuleParticipantChangedEvent", context: context);
        }
        
        public enum Action {
            case joined
            case left
        }
    }
    
    open class ChannelPermissionsChangedEvent: AbstractEvent {
        
        public static let TYPE = ChannelPermissionsChangedEvent();

        public let channel: ChannelProtocol!;

        init() {
            self.channel = nil;
            super.init(type: "MixModuleChannelPermissionsChangedEvent");
        }
        
        public init(context: Context, channel: ChannelProtocol) {
            self.channel = channel;
            super.init(type: "MixModuleChannelPermissionsChangedEvent", context: context);
        }
    }

    public typealias ParticipantsResult = Result<[MixParticipant],XMPPError>
    public typealias PermissionsResult = Result<[ChannelPermission],XMPPError>
    
}

open class MixInvitation {
    public let inviter: BareJID;
    public let invitee: BareJID;
    public let channel: BareJID;
    public let token: String?;
    
    public convenience init?(from el: Element?) {
        guard el?.name == "invitation" && el?.xmlns == "urn:xmpp:mix:misc:0" else {
            return nil;
        }
        guard let inviter = BareJID(el?.findChild(name: "inviter")?.value), let invitee = BareJID(el?.findChild(name: "invitee")?.value), let channel = BareJID(el?.findChild(name: "channel")?.value) else {
            return nil;
        }
        self.init(inviter: inviter, invitee: invitee, channel: channel, token: el?.findChild(name: "token")?.value);
    }
    
    public init(inviter: BareJID, invitee: BareJID, channel: BareJID, token: String?) {
        self.inviter = inviter;
        self.invitee = invitee;
        self.channel = channel;
        self.token = token;
    }
    
    open func element() -> Element {
        return Element(name: "invitation", xmlns: "urn:xmpp:mix:misc:0", children: [
            Element(name: "inviter", cdata: inviter.stringValue),
            Element(name: "invitee", cdata: invitee.stringValue),
            Element(name: "channel", cdata: channel.stringValue),
            Element(name: "token", cdata: token)
        ]);
    }
}

extension Message {
    open var mixInvitation: MixInvitation? {
        get {
            return MixInvitation(from: findChild(name: "invitation", xmlns: "urn:xmpp:mix:misc:0"));
        }
        set {
            element.removeChildren(where: { $0.name == "invitation" && $0.xmlns == "urn:xmpp:mix:misc:0"});
            if let value = newValue {
                element.addChild(value.element());
            }
        }
    }
}
