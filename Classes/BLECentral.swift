//
//  BLECentral.swift
//  Actors
//
//  Created by Dario Lencina on 9/27/15.
//  Copyright © 2015 dario. All rights reserved.
//

import Foundation
import CoreBluetooth


/**
BLECentral is a wrapper for CBCentralManager which allows developers to interact with CoreBluetooth using actors as opposed to the callback oriented approach of Apple.
*/

public class BLECentral : Actor, CBCentralManagerDelegate, WithListeners {
    
    /**
     Peripheral connection default options
    */
    
    let peripheralConnectionOptions = [CBConnectPeripheralOptionNotifyOnConnectionKey : true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey : true,
        CBConnectPeripheralOptionNotifyOnNotificationKey : true]
    
    /**
     Human readable Central states
    */
    
    private struct States {
        let scanning : String = "scanning"
        let notScanning : String = "notScanning"
        let connecting = "connecting"
        let connected = "connected"
    }
    
    /**
     Human readable Central states
     */
    
    private let states = States()
    
    /**
    CBCentralManager scanner options, this will be exposed as a message in new versions of Theater
    */
    
    private let bleOptions = [CBCentralManagerScanOptionAllowDuplicatesKey : NSNumber(bool: true)]
    
    /**
    This collection stores all peripheral observations, it would be nice to add a method to purge it.
    */
    
    private var observations : PeripheralObservations = PeripheralObservations()
    
    /**
    Underlying CBCentralManager
    */
    
    private var central : CBCentralManager
    
    /**
    This flag is used as a semaphore and avoids bombing other actors with PeripheralObservations
    */
    
    private var shouldWait = false
    
    //TODO expose this variable
    
    private var threshold : Double = 5
    
    /**
    Collection with actors that care about changes in BLECentral
    */
    
    public var listeners : [ActorRef] = []
    
    /**
    PeripheralConnections
    */
    
    private var connections : PeripheralConnections = PeripheralConnections()
    
    /**
    This is the constructor used by the ActorSystem, do not call it directly
    */
    
    public required init(context: ActorSystem, ref: ActorRef) {
        self.central = CBCentralManager() // stupid swift
        super.init(context: context, ref: ref)
        self.central = CBCentralManager(delegate: self, queue: self.mailbox.underlyingQueue)
    }
    
    /**
    Initializes the BLECentral in the notScanning state
    */
    
    override public func preStart() {
        super.preStart()
        self.become(self.states.notScanning, state: self.notScanning)
    }
    
    /**
     Scanning state message handler
    */
    
    private func scanning(services : Optional<[CBUUID]>) -> Receive {
        self.shouldWait = false
        
        return {[unowned self] (msg : Actor.Message) in
            switch (msg) {
                
                case is StateChanged:
                    if self.central.state == .PoweredOn {
                        self.this ! StartScanning(services: services, sender: self.this)
                    }
                
                case is StartScanning:
                    self.central.scanForPeripheralsWithServices(services, options: self.bleOptions)
                
                case is StopScanning:
                    self.central.stopScan()
                    self.popToState(self.states.notScanning)
                    
                case let m as Peripheral.Connect:
                    self.central.connectPeripheral(m.peripheral, options: self.peripheralConnectionOptions)
                
                case let m as Peripheral.OnConnect:
                    let id = m.peripheral.identifier
                    let c = self.context.actorOf(BLEPeripheralConnection.self, name: id.UUIDString)
                    self.connections[id] = c
                    c ! BLEPeripheralConnection.SetPeripheral(sender: self.this, peripheral: m.peripheral)
                    self.broadcast(Peripheral.OnConnect(sender: self.this, peripheral: m.peripheral, peripheralConnection: c))
                
                case let m as Peripheral.OnDisconnect:
                    let id = m.peripheral.identifier
                    if let c = self.connections[id] {
                        c ! Harakiri(sender: self.this)
                    }
                    self.connections.removeValueForKey(m.peripheral.identifier)
                    self.broadcast(m)                
                    
                case let m as Peripheral.Disconnect:
                    self.central.cancelPeripheralConnection(m.peripheral)
                
                default:
                    self.notScanning(msg)
            }
        }
    }
    
    /**
     Not scanning state Actor.Message handler
     */
    
    lazy private var notScanning : Receive = {[unowned self](msg : Actor.Message) in
        switch (msg) {
                
            case let m as StartScanning:
                self.become(self.states.scanning, state: self.scanning(m.services))
                self.addListener(m.sender)
                self.this ! m

            case is StopScanning:
                print("not scanning")

            case let m as RemoveListener:
                self.removeListener(m.sender)

            case let m as AddListener:
                self.addListener(m.sender)

            case is Harakiri:
                self.context.stop(self.this)

            default:
                print("not handled")
        }
    }
    
    /**
    CBCentralManagerDelegate methods, BLECentral hides this methods so that messages can interact with BLE devices using actors
    */
    
    @objc public func centralManagerDidUpdateState(central: CBCentralManager) {
        let state = CBCentralManagerState.init(rawValue: central.state.rawValue)!
        let stateChanged = StateChanged(sender: this, state: state)
        this ! stateChanged
        listeners.forEach { (listener) in listener ! stateChanged }
    }
    
    /**
    CBCentralManagerDelegate methods, BLECentral hides this methods so that messages can interact with BLE devices using actors
    */
    
    @objc public func centralManager(central: CBCentralManager, willRestoreState dict: [String : AnyObject]) {
        
    }
    
    /**
    CBCentralManagerDelegate methods, BLECentral hides this methods so that messages can interact with BLE devices using actors
    */
    
    @objc public func centralManager(central: CBCentralManager, didDiscoverPeripheral peripheral: CBPeripheral, advertisementData: [String : AnyObject], RSSI: NSNumber) {
        
        let bleDevice = BLEPeripheralObservation(peripheral: peripheral, advertisementData: advertisementData, RSSI: RSSI, timestamp: NSDate.init())
        if var historyOfDevice = self.observations[peripheral.identifier.UUIDString], let lastObv = historyOfDevice.first {
            let areRSSIDifferent = abs(lastObv.RSSI.doubleValue - bleDevice.RSSI.doubleValue) > 20
            let isThereEnoughTimeBetweenSamples = Double(bleDevice.timestamp.timeIntervalSinceDate(lastObv.timestamp)) > threshold
            if  areRSSIDifferent || isThereEnoughTimeBetweenSamples {
                historyOfDevice.insert(bleDevice, atIndex: 0)
                self.observations[peripheral.identifier.UUIDString] = historyOfDevice
            }
        } else {
            self.observations[peripheral.identifier.UUIDString] = [bleDevice]
        }
        
        if shouldWait { return }
        
        shouldWait = true
        
        self.scheduleOnce(1,block: { () in
            self.shouldWait = false
        })
        
        listeners.forEach { (listener) -> () in
            listener ! DevicesObservationUpdate(sender: this, devices: self.observations)
        }
    }
    
    /**
    CBCentralManagerDelegate methods, BLECentral hides this methods so that messages can interact with BLE devices using actors
    */
    
    @objc public func centralManager(central: CBCentralManager, didConnectPeripheral peripheral: CBPeripheral) {
        this ! Peripheral.OnConnect(sender: this, peripheral: peripheral, peripheralConnection: nil)
    }
    
    /**
    CBCentralManagerDelegate methods, BLECentral hides this methods so that messages can interact with BLE devices using actors
    */
    
    @objc public func centralManager(central: CBCentralManager, didFailToConnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        this ! Peripheral.OnDisconnect(sender: this, peripheral: peripheral, error: error)
    }
    
    /**
    CBCentralManagerDelegate methods, BLECentral hides this methods so that messages can interact with BLE devices using actors
    */

    @objc public func centralManager(central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: NSError?) {
        this ! Peripheral.OnDisconnect(sender: this, peripheral: peripheral, error: error)
    }
    
    deinit {
        self.central.delegate = nil
        print("called deinit in BLECentral \(this.path.asString)")
    }
    
}
