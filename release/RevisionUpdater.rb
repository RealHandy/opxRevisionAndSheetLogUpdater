# RevisionUpdater.rb
# If there is an installed macro, ThisApplication.rb sets the env variable. Otherwise, I'm working in RevitRubyShell and working from my repo dir.
revitrubyshell_file_load_path = 'S:\\OPX_StuffFOLDERS\\SoftwareDev\\Revit\\opxRevisionAndSheetLogUpdater'
file_load_path = ENV.fetch("opx_file_load_path")
file_load_path ||= revitrubyshell_file_load_path
$LOAD_PATH.unshift(file_load_path)
$is_revitrubyshell = ( file_load_path == revitrubyshell_file_load_path )

require 'dbgp'
include OPX
dbgp "Loading revisionUpdater.rb"
require 'UpdateSheetRevisions'

load_assembly 'RevitAPI'
load_assembly 'RevitAPIUI'
include Autodesk::Revit
include Autodesk::Revit::UI
include Autodesk::Revit::DB
include Autodesk::Revit::DB::Architecture

module OPX

$revision_name_param_name = "Revision Description"

# For whatever reason, the C:\Program Files\Autodesk\Revit 2014 directory is listed as the default directory.
#$LOAD_PATH.unshift(File.expand_path(File.dirname(__FILE__)))
#puts "current path is #{File.expand_path(File.dirname(__FILE__))}"

#------------------------------------
# Updater that is triggered when adding a new Revision via View/Revisions
#------------------------------------
class RevisionUpdater
    include Autodesk::Revit::DB::IUpdater

    @@updater_name = "OPX Revision Updater"
    def self.updater_name
        return @@updater_name
    end

    attr_accessor :app_id, :updater_id # AddInId, # UpdaterId
    
    #----------------
    # constructor takes the AddInId for the add-in associated with this updater
    def initialize(id)  # AddInId
            @app_id = id
            @updater_id = UpdaterId.new(@app_id, System::Guid.new(System::String.new("CA2EB5E3-D847-4822-8D2E-EB189430B322")))
    end

    #----------------
    def Execute(data)  # UpdaterData
        doc = data.GetDocument()
        sub_txn = nil
        begin

        # If this is a new revision, add a parameter and field to the sheets and sheet list.
        new_rev_ids = data.GetAddedElementIds()
        new_rev_ids.each do |new_rev_id|
            rev = doc.GetElement(new_rev_id)
            # Adding the field to the sheet list automatically adds it to all the sheets.   
            new_rev_name = rev.get_Parameter( $revision_name_param_name ).AsString()
            dbgp "Updater for new revision #{new_rev_name}"
            sub_txn ||= get_and_start_subtxn( doc )
            sched = schedule_from_name( doc, $sheet_issue_log_name )
            add_new_field_to_sheet_list( sched, new_rev_name, ParameterType.YesNo, sub_txn )
        end

        # If the description of the revision changed, change the parameter and field name in the sheets and sheet list.
        # Nope! API-created rev-named parameters must be shared parameters. Shared parameters cannot be renamed.
        # So for now, UNCHANGE the name of a rev if a user changes it? Also nope! revision description is a read-only parameter.
        # Create a new parameter with the new rev name, copy all the sheet settings from the old name param to the new one,
        # and delete the old param.
        changed_rev_ids = data.GetModifiedElementIds()
        changed_rev_ids.each do |changed_rev_id|
            rev = doc.GetElement(changed_rev_id)
            new_rev_name = rev.get_Parameter($revision_name_param_name).AsString()
            dbgp "Updater for changed revision #{changed_rev_id.IntegerValue} - #{new_rev_name}"

            # Get the old rev name param.
            sched = schedule_from_name( doc, $sheet_issue_log_name )
            old_rev_name_param = rev_param_not_matching_any_rev_name( sched )
            if old_rev_name_param
                old_rev_name = old_rev_name_param.Definition.Name
                
                # Create a param with the new rev name and add it at the column position of the old rev-named param.
                sub_txn ||= get_and_start_subtxn( doc )
                atIndex = schedule_field_from_name( sched, old_rev_name ).FieldIndex
                add_field_to_sheet_list( sched, new_rev_name, ParameterType.YesNo, sub_txn, atIndex )

                # Copy the value of the old param to the new param for every sheet.
                dbgp "Copying values from #{old_rev_name} to #{new_rev_name}"
                sheets = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Sheets)
                sheets.each do |sheet|
                    # Copy the value of the old param to the new param.
                    #sheet.get_Parameter( new_rev_name ).Set( sheet.get_Parameter( old_rev_name ).AsValueString() == "Yes" ? 1 : 0 )
                    set_rev_param_on_sheet( sheet, sheet.get_Parameter( new_rev_name ), sheet.get_Parameter( old_rev_name ).AsValueString() == "Yes" ? 1 : 0 )
                end

                # Remove the old param from the sheet list.
                remove_field_from_sheet_list( sched, old_rev_name, sub_txn )

                # Delete the old param. As of 2014 Update 1, this leaves a greyed-out param in the sheet that can't be clicked or removed if
                # the param was ever set to a value. It will not leave the param in the sheet if the param was never set. Since I'm setting
                # every param to No to help with the appearance of the sheet log, these params are never going away.
                delete_shared_parameter( sched, old_rev_name_param, sub_txn )

            end
        end

        # There's no point in this. Merging revs doesn't trigger it.
        #deleted_rev_ids = data.GetDeletedElementIds()
        #deleted_rev_ids.each do |deleted_rev_id|
           #dbgp "deleted rev #{deleted_rev_id.IntegerValue}"
            # This next line fails. The element is gone already.
            #rev = doc.GetElement(deleted_rev_id)
            #dbgp "Updater for deleted revision #{rev.ParametersMap.Item($revision_name_param_name).AsString()}"        
        #end

        if sub_txn
            sub_txn.Commit()
        end
        rescue Exception => e
            report_error( "Exception" )
            report_error( e.to_s )
            raise
        end
    end

    #------------------
    def self.register_updater( app, doc = nil )
        begin
        
            dbgp "Register RevisionUpdater with ActiveAddInId #{app.ActiveAddInId.GetGUID().to_s}"
        
            # Get a doc.
            dbgp "Doc template is #{app.DefaultProjectTemplate}"
            doc ||= app.NewProjectDocument( app.DefaultProjectTemplate )
            dbgp "Doc is #{doc.Title}"
            
            updater = RevisionUpdater.new( app.ActiveAddInId )
            dbgp "Updater id is #{updater.GetUpdaterId().GetGUID()}"
        
            UpdaterRegistry.RegisterUpdater(updater)
            dbgp "RegisterUpdater call completed"
         
            # Change Scope = any rev element
            rev_filter = ElementCategoryFilter.new(BuiltInCategory.OST_Revisions)
            dbgp "rev_filter is #{rev_filter}"
         
            # To get the revision description parameter to check for changed rev names,
            # there has to be at least one rev in the project that has the parameter in it. Get it.
            desc_param = nil
            
            revs = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Revisions)
            revs.each do |rev|
                dbgp "#{rev.get_Parameter( $revision_name_param_name ).AsString()}"
                param = rev.get_Parameter( $revision_name_param_name )
                if param
                    dbgp "has #{$revision_name_param_name}"
                    desc_param = param
                    dbgp "desc_param is #{desc_param}"
                    break
                end
            end
            UpdaterRegistry.AddTrigger( updater.GetUpdaterId(), rev_filter,
                ChangeType.ConcatenateChangeTypes( Element.GetChangeTypeElementAddition(),
                                                   Element.GetChangeTypeParameter( desc_param ) ) )
        #            ChangeType.ConcatenateChangeTypes( Element.GetChangeTypeElementDeletion(), Element.GetChangeTypeParameter( desc_param )  ) ) )
    
            return updater, doc
        rescue Exception => e
            report_error( "Exception" )
            report_error( e.to_s )
            raise
        end
    end

    #---------------
    def self.unregister_updater( app, updater = nil )
        updater ||= RevisionUpdater.new( app.ActiveAddInId )
        dbgp "UN-register RevisionUpdater with GUID #{updater.GetUpdaterId().GetGUID()}, ActiveAddInId #{app.ActiveAddInId.GetGUID().to_s}"
        UpdaterRegistry.UnregisterUpdater(updater.GetUpdaterId())
    end

    #----------------
    def GetAdditionalInformation()
        return "OPX Revision updater: adds/changes/deletes a field in Sheet Log with the same name as the Revision (field is also used by Sheet Revision Change updater."
    end

    #----------------
    def GetChangePriority()
        return ChangePriority.Views
    end

    #----------------
    def GetUpdaterId()
        return @updater_id
    end
    
    #----------------
    def GetUpdaterName()
        return @@updater_name
    end
end

end

