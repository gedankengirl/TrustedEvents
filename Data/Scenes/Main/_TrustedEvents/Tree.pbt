Name: "_TrustedEvents"
RootId: 7464206498429841281
Objects {
  Id: 12452661915799896411
  Name: "TrustedEvents_README"
  Transform {
    Location {
    }
    Rotation {
    }
    Scale {
      X: 1
      Y: 1
      Z: 1
    }
  }
  ParentId: 7464206498429841281
  Collidable_v2 {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  Visible_v2 {
    Value: "mc:evisibilitysetting:inheritfromparent"
  }
  CameraCollidable {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  EditorIndicatorVisibility {
    Value: "mc:eindicatorvisibility:visiblewhenselected"
  }
  Script {
    ScriptAsset {
      Id: 16125848706268628621
    }
  }
  InstanceHistory {
    SelfId: 12452661915799896411
    SubobjectId: 5452788899441613321
    InstanceId: 2675379327775575188
    TemplateId: 15711733878564221137
  }
}
Objects {
  Id: 6802279960191285471
  Name: "TrustedEventsHost"
  Transform {
    Location {
    }
    Rotation {
    }
    Scale {
      X: 1
      Y: 1
      Z: 1
    }
  }
  ParentId: 7464206498429841281
  UnregisteredParameters {
    Overrides {
      Name: "cs:0xFF"
      String: ""
    }
    Overrides {
      Name: "cs:0xFF:isrep"
      Bool: true
    }
  }
  WantsNetworking: true
  Collidable_v2 {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  Visible_v2 {
    Value: "mc:evisibilitysetting:inheritfromparent"
  }
  CameraCollidable {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  EditorIndicatorVisibility {
    Value: "mc:eindicatorvisibility:visiblewhenselected"
  }
  Folder {
    IsFilePartition: true
    FilePartitionName: "TrustedEventsHost"
  }
  InstanceHistory {
    SelfId: 6802279960191285471
    SubobjectId: 13337974351641011085
    InstanceId: 2675379327775575188
    TemplateId: 15711733878564221137
  }
}
Objects {
  Id: 12229115584439479579
  Name: "ClientContext"
  Transform {
    Location {
    }
    Rotation {
    }
    Scale {
      X: 1
      Y: 1
      Z: 1
    }
  }
  ParentId: 7464206498429841281
  ChildIds: 17500908829251110912
  UnregisteredParameters {
  }
  Collidable_v2 {
    Value: "mc:ecollisionsetting:forceoff"
  }
  Visible_v2 {
    Value: "mc:evisibilitysetting:inheritfromparent"
  }
  CameraCollidable {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  EditorIndicatorVisibility {
    Value: "mc:eindicatorvisibility:visiblewhenselected"
  }
  NetworkContext {
  }
  InstanceHistory {
    SelfId: 12229115584439479579
    SubobjectId: 5677358255783130697
    InstanceId: 2675379327775575188
    TemplateId: 15711733878564221137
  }
}
Objects {
  Id: 17500908829251110912
  Name: "TrustedEventsClient"
  Transform {
    Location {
    }
    Rotation {
    }
    Scale {
      X: 1
      Y: 1
      Z: 1
    }
  }
  ParentId: 12229115584439479579
  UnregisteredParameters {
    Overrides {
      Name: "cs:TrustedEventsHost"
      ObjectReference {
        SelfId: 6802279960191285471
      }
    }
  }
  Collidable_v2 {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  Visible_v2 {
    Value: "mc:evisibilitysetting:inheritfromparent"
  }
  CameraCollidable {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  EditorIndicatorVisibility {
    Value: "mc:eindicatorvisibility:visiblewhenselected"
  }
  Script {
    ScriptAsset {
      Id: 3675807310091147788
    }
  }
  InstanceHistory {
    SelfId: 17500908829251110912
    SubobjectId: 1559155106944013138
    InstanceId: 2675379327775575188
    TemplateId: 15711733878564221137
  }
}
Objects {
  Id: 15624722772116851750
  Name: "ServerContext"
  Transform {
    Location {
    }
    Rotation {
    }
    Scale {
      X: 1
      Y: 1
      Z: 1
    }
  }
  ParentId: 7464206498429841281
  ChildIds: 3421084829416535453
  Collidable_v2 {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  Visible_v2 {
    Value: "mc:evisibilitysetting:inheritfromparent"
  }
  CameraCollidable {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  EditorIndicatorVisibility {
    Value: "mc:eindicatorvisibility:visiblewhenselected"
  }
  NetworkContext {
    Type: Server
  }
  InstanceHistory {
    SelfId: 15624722772116851750
    SubobjectId: 4587661722996414324
    InstanceId: 2675379327775575188
    TemplateId: 15711733878564221137
  }
}
Objects {
  Id: 3421084829416535453
  Name: "TrustedEventsServer"
  Transform {
    Location {
    }
    Rotation {
    }
    Scale {
      X: 1
      Y: 1
      Z: 1
    }
  }
  ParentId: 15624722772116851750
  UnregisteredParameters {
    Overrides {
      Name: "cs:TrustedEventsHost"
      ObjectReference {
        SelfId: 6802279960191285471
      }
    }
  }
  Collidable_v2 {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  Visible_v2 {
    Value: "mc:evisibilitysetting:inheritfromparent"
  }
  CameraCollidable {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  EditorIndicatorVisibility {
    Value: "mc:eindicatorvisibility:visiblewhenselected"
  }
  Script {
    ScriptAsset {
      Id: 4909483585225202872
    }
  }
  InstanceHistory {
    SelfId: 3421084829416535453
    SubobjectId: 14413399053922037455
    InstanceId: 2675379327775575188
    TemplateId: 15711733878564221137
  }
}
Objects {
  Id: 10344095373725678326
  Name: "ModuleContainer"
  Transform {
    Location {
    }
    Rotation {
    }
    Scale {
      X: 1
      Y: 1
      Z: 1
    }
  }
  ParentId: 7464206498429841281
  UnregisteredParameters {
    Overrides {
      Name: "cs:AckAbility"
      AssetReference {
        Id: 2765636799855673298
      }
    }
    Overrides {
      Name: "cs:Base64"
      AssetReference {
        Id: 17269496465138592771
      }
    }
    Overrides {
      Name: "cs:BitVector32"
      AssetReference {
        Id: 9387299497344874910
      }
    }
    Overrides {
      Name: "cs:Config"
      AssetReference {
        Id: 488210722089865437
      }
    }
    Overrides {
      Name: "cs:Maid"
      AssetReference {
        Id: 16867799801641793617
      }
    }
    Overrides {
      Name: "cs:MessagePack"
      AssetReference {
        Id: 11047531607100079355
      }
    }
    Overrides {
      Name: "cs:Queue"
      AssetReference {
        Id: 1331718247682064379
      }
    }
    Overrides {
      Name: "cs:ReliableEndpoint"
      AssetReference {
        Id: 6379868446302775488
      }
    }
    Overrides {
      Name: "cs:Signals"
      AssetReference {
        Id: 2268609786492532760
      }
    }
    Overrides {
      Name: "cs:TrustedEvents"
      AssetReference {
        Id: 10999198869143869747
      }
    }
    Overrides {
      Name: "cs:UnreliableEndpoint"
      AssetReference {
        Id: 17737735706392805187
      }
    }
    Overrides {
      Name: "cs:AckAbility:tooltip"
      String: "Module for sending  messages through the Ability"
    }
    Overrides {
      Name: "cs:Base64:tooltip"
      String: "Base64 encoding/decoding"
    }
    Overrides {
      Name: "cs:BitVector32:tooltip"
      String: "BitVector32 data structure"
    }
    Overrides {
      Name: "cs:Config:tooltip"
      String: "A very simple module for handling read-only key-value configuration files."
    }
    Overrides {
      Name: "cs:Maid:tooltip"
      String: "Module for resource management "
    }
    Overrides {
      Name: "cs:MessagePack:tooltip"
      String: "MessagePack serialization with Core support"
    }
    Overrides {
      Name: "cs:Queue:tooltip"
      String: "Queue data structure"
    }
    Overrides {
      Name: "cs:ReliableEndpoint:tooltip"
      String: "Custom Implementation of \"Selective Repeat Request\" network protocol."
    }
    Overrides {
      Name: "cs:TrustedEvents:tooltip"
      String: "Trusted Events API"
    }
  }
  Collidable_v2 {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  Visible_v2 {
    Value: "mc:evisibilitysetting:inheritfromparent"
  }
  CameraCollidable {
    Value: "mc:ecollisionsetting:inheritfromparent"
  }
  EditorIndicatorVisibility {
    Value: "mc:eindicatorvisibility:visiblewhenselected"
  }
  Folder {
    IsFilePartition: true
    FilePartitionName: "ModuleContainer"
  }
  InstanceHistory {
    SelfId: 10344095373725678326
    SubobjectId: 7561851069677887908
    InstanceId: 2675379327775575188
    TemplateId: 15711733878564221137
  }
}
