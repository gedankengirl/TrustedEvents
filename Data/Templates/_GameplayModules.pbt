Assets {
  Id: 915022728116404952
  Name: "@GameplayModules"
  PlatformAssetType: 5
  TemplateAsset {
    ObjectBlock {
      RootId: 1497744498325745006
      Objects {
        Id: 1497744498325745006
        Name: "@GameplayModules"
        Transform {
          Scale {
            X: 1
            Y: 1
            Z: 1
          }
        }
        ParentId: 4781671109827199097
        ChildIds: 8776622154302076956
        ChildIds: 17857286940596998996
        UnregisteredParameters {
          Overrides {
            Name: "cs:Agent"
            AssetReference {
              Id: 13884484637249078194
            }
          }
          Overrides {
            Name: "cs:CharacterController"
            AssetReference {
              Id: 4463537768691038536
            }
          }
          Overrides {
            Name: "cs:DebugDraw"
            AssetReference {
              Id: 10817286341666567126
            }
          }
          Overrides {
            Name: "cs:Grid"
            AssetReference {
              Id: 12769054960477199651
            }
          }
          Overrides {
            Name: "cs:SpringAnimator"
            AssetReference {
              Id: 15795618890956269941
            }
          }
          Overrides {
            Name: "cs:StateMachine"
            AssetReference {
              Id: 15572707156245510975
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
        Folder {
          IsFilePartition: true
        }
      }
      Objects {
        Id: 8776622154302076956
        Name: "InitModules"
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
        ParentId: 1497744498325745006
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
            Id: 4105323538164046505
          }
        }
      }
      Objects {
        Id: 17857286940596998996
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
        ParentId: 1497744498325745006
        ChildIds: 11325870195518683980
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
      }
      Objects {
        Id: 11325870195518683980
        Name: "InitModules"
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
        ParentId: 17857286940596998996
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
            Id: 4105323538164046505
          }
        }
      }
    }
    PrimaryAssetId {
      AssetType: "None"
      AssetId: "None"
    }
  }
  SerializationVersion: 92
}
