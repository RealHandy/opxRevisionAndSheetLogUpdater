
load_assembly "RevitAPI"
load_assembly "RevitAPIUI"

include Autodesk::Revit::DB
include Autodesk::Revit::UI
include Autodesk::Revit::UI::Selection
include System::Collections::Generic
include System::Collections
include System

# Set the env var to the Revit macro project path.
file_load_path = 'C:\\ProgramData\\Autodesk\\Revit\\Macros\\2014\\Revit\\AppHookup\\opxRevisionAndSheetLogUpdater\\Source\\opxRevisionAndSheetLogUpdater'
ENV["opx_file_load_path"] = file_load_path
$LOAD_PATH.unshift(file_load_path)
require 'revisionUpdater'
require 'sheetRevisionChangeUpdater'


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
		@revisions_updater = revisions_register_updater( self.Application )
	    dbgp "Registered the revisions_updater"
		@sheets_updater = sheets_register_updater( self, self.Application )
	    dbgp "Registered the sheets_updater"
    end
    
    def Shutdown
		revisions_unregister_updater( self.Application, @revisions_updater )    	
		sheets_unregister_updater( self, self.Application, @sheets_updater )    	
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
