# ThisApplication.rb
# Set the env var to the Revit macro project path.
file_load_path = 'C:\\ProgramData\\Autodesk\\Revit\\Macros\\2014\\Revit\\AppHookup\\opxRevisionAndSheetLogUpdater\\Source\\opxRevisionAndSheetLogUpdater'
ENV["opx_file_load_path"] = file_load_path
$LOAD_PATH.unshift(file_load_path)

require 'dbgp'
include OPX
require 'RevisionUpdater'
require 'SheetRevisionChangeUpdater'

load_assembly "RevitAPI"
load_assembly "RevitAPIUI"
include Autodesk::Revit::DB
include Autodesk::Revit::UI
include Autodesk::Revit::UI::Selection
include System::Collections::Generic
include System::Collections
include System

class ThisApplication < Autodesk::Revit::UI::Macros::ApplicationEntryPoint
	
	attr_accessor :revisions_updater, :sheets_updater
	
	#region Revit Macros generated code
    protected
    def FinishInitialization
    	super
    	self.InternalStartup
    end
    
    def OnShutdown
    	self.InternalShutdown
    	super
    end
    
    def InternalStartup
    	self.Startup
    end
    
    def InternalShutdown
    	self.Shutdown
    end
    #endregion
    
    protected
    def Startup
        OPX.dbgp "Getting registered updater infos"
        installed_updaters_info = UpdaterRegistry.GetRegisteredUpdaterInfos()
        OPX.dbgp "Checking for registered OPX updaters"
        installed_updaters_info.each do |info|
            OPX.dbgp "Found installed updater #{info.UpdaterName}"
            if info.UpdaterName == OPX::RevisionUpdater.updater_name
                OPX.dbgp "Unregistering existing #{info.UpdaterName} with #{self.Application}, #{@revisions_updater}"
                OPX::RevisionUpdater.unregister_updater( self.Application, @revisions_updater )       
            elsif info.UpdaterName == OPX::SheetRevisionChangeUpdater.updater_name
                OPX.dbgp "Unregistering existing #{info.UpdaterName}"
                OPX::SheetRevisionChangeUpdater.unregister_updater( self, self.Application, @sheets_updater )     
            end
        end
		@revisions_updater = OPX::RevisionUpdater.register_updater( self.Application )
	    OPX.dbgp "Registered the revisions_updater"
		@sheets_updater = OPX::SheetRevisionChangeUpdater.register_updater( self, self.Application )
	    OPX.dbgp "Registered the sheets_updater"
    end
    
    def Shutdown
		OPX::RevisionUpdater.unregister_updater( self.Application, @revisions_updater )    	
		OPX::SheetRevisionChangeUpdater.unregister_updater( self, self.Application, @sheets_updater )    	
    end
    
	# Transaction mode
    public
    def GetTransactionMode()
    	return Autodesk::Revit::Attributes::TransactionMode.Manual
    end
    
	# Addin Id
    def GetAddInId()
    	return System::String.new("2E8A3EDA-9DE1-46E7-BBEC-020F43D7556D")
    end
end
