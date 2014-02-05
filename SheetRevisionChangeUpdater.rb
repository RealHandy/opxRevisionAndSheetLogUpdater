# SheetRevisionChangeUpdater.rb
# ThisApplication.rb sets the env variable. Otherwise, I'm working in RevitRubyShell and working from my repo dir.
revitrubyshell_file_load_path = 'S:\\OPX_StuffFOLDERS\\SoftwareDev\\Revit\\opxRevisionAndSheetLogUpdater'
file_load_path = ENV.fetch("opx_file_load_path")
file_load_path ||= revitrubyshell_file_load_path
$LOAD_PATH.unshift(file_load_path)
$is_revitrubyshell = ( file_load_path == revitrubyshell_file_load_path )

require 'dbgp'
include OPX
dbgp "Loading sheetRevisionChangeUpdater.rb"
require 'UpdateSheetRevisions'
#require 'SheetRevParamEntity'

load_assembly 'RevitAPI'
load_assembly 'RevitAPIUI'
include Autodesk::Revit
include Autodesk::Revit::UI
include Autodesk::Revit::DB
include Autodesk::Revit::DB::Architecture
include Autodesk::Revit::DB::Events

module OPX

$revision_name_param_name = "Revision Description"

#------------------------------------
# Updater that is triggered when checking a Revision on Sheet
#------------------------------------
class SheetRevisionChangeUpdater
    include Autodesk::Revit::DB::IUpdater

    @@updater_name = "OPX Sheet Revision Change Updater"
    def self.updater_name
        return @@updater_name
    end

    attr_accessor :app_id, :updater_id, :rev_updates_to_force, :rev_updates_exist # AddInId, # UpdaterId, # hash of k=sheet, v=rev_id, bool
    
    #----------------
    # constructor takes the AddInId for the add-in associated with this updater
    def initialize(id)  # AddInId
        @app_id = id
        @updater_id = UpdaterId.new( @app_id, System::Guid.new(System::String.new("BF468CCC-8DF2-4C8B-BFAA-66F6E2A797C9")) )
        @rev_updates_to_force = Hash.new
        @rev_updates_exist = false
    end

    #----------------
    def Execute(data)  # UpdaterData
        doc = data.GetDocument()
        sub_txn = nil
        begin
        # Get the list of all params that are named after revs. This is to see if the change is an ANY or PARAMETER change.
        # Just do this every time, since it's fast, easier, and less error-prone than trying to cache them across Execute() actions.
        param_list = rev_named_params_list( doc )

        # Get a map of revisions by name, for performance reasons.
        revs_map = revisions_map_by_name( doc )

        # Loop through each of the sheet elements that has changed. If any of our rev-named parameters have changed,
        # then this Execute() is due to a person checking/unchecking those parameters.
        # This whole approach only works because I've confirmed via testing that a trigger
        # to a specific parameter does not also trigger a GetChangeTypeAny.
        # Therefore:
        #   If trigger is on one of our rev-named parameters, then the user checked/unchecked one of those.
        #   Otherwise, check for a GetChangeTypeAny to see if the user checked/unchecked a Revision on Sheet.
        changed_param = nil
        changed_ids = data.GetModifiedElementIds()
        dbgp "Got data"
        sheet = nil

        changed_ids.each do |id|
            sheet = doc.GetElement( id )
            dbgp "Working on change of: #{sheet.Name}, Type: #{sheet.GetType().Name}"
            # Check if each rev-named parameter was changed.
            # There could be more than one rev param changed at the same time.
            param_list.each do |param|
                dbgp "Param id is #{param.Id}, name is #{param.Definition.name}", 2
                if data.IsChangeTriggered( id, Element.GetChangeTypeParameter( param ) )
                    dbgp "PARAMETER change for: #{sheet.Name}, Param: #{param.Definition.Name}"
                    changed_param = param
                    sheet_param = sheet.get_Parameter( param.Definition.Name )
                    is_checked = sheet_param.AsValueString() == "Yes"
                    dbgp "#{param.Definition.Name} = #{sheet_param.AsValueString()}, is_checked = #{is_checked}"
                    #rev = revision_from_name( doc, param.Definition.Name )
                    rev = revs_map[param.Definition.Name]
                    dbgp "rev id is #{rev.Id}"
                    if ( is_checked and (not sheet_contains_rev_id( sheet, rev.Id )) )
                        # The param is checked but the revision isn't in Revisions on Sheet, so add the rev to Revisions on Sheet.
                        dbgp "Adding rev for param #{param.Definition.Name}"
                        sub_txn ||= get_and_start_subtxn( doc )
                        add_rev_id_to_sheet( sheet, rev.Id, sub_txn )
                        set_rev_update_to_force( sheet, rev.Id )
                        # If there are no rev clouds for this rev in this sheet (which should be so), set the manually checked flag in the param.
                        #if not sheet_has_rev_clouds_for_revision( sheet, rev.Id )
                            #set_sheet_param_flag( sheet_param, "manually_checked", true )
                            #set_sheet_param_flag( sheet_param, "has_rev_clouds", false )
                        #end
                    elsif ( (not is_checked) and sheet_contains_removable_rev_id( sheet, rev.Id ) )
                        # The param is NOT checked but the revision IS in Revisions on Sheet and removable, so remove the rev from Revisions on Sheet.
                        # NOTE: as of 2014 Update 1, Revit works differently (and better) with RevisionsOnSheet, but there is no way to tell
                        # if a rev that has been checked is ALSO containing a rev cloud, so this code executes, but Revit doesn't allow the removable
                        # rev id to be removed and behaves in a way that re-checks the rev param, so this code path executes over and over if the
                        # user is trying to uncheck a removable rev that has a rev cloud.
                        dbgp "Unchecking param #{param.Definition.Name}"
                        sub_txn ||= get_and_start_subtxn( doc )
                        remove_rev_id_from_sheet( sheet, rev.Id, sub_txn )
                        set_rev_update_to_force( sheet, rev.Id )
                        # Unset the manually checked flag in the param.
                        #set_sheet_param_flag( sheet_param, "manually_checked", false )
                        #set_sheet_param_flag( sheet_param, "has_rev_clouds", false )
                    elsif ( (not is_checked) and sheet_contains_rev_id( sheet, rev.Id ) )
                        # The param is NOT checked, but the revision IS in Revisions on Sheet and is NOT removable, so recheck the param.
                        # It can't be marked unchecked because there is a revision cloud revision for this rev name.
                        dbgp "Re-checking param #{param.Definition.Name}, since rev cloud exists"
                        TaskDialog.Show( "Macro", "A revision cloud exists for #{param.Definition.Name} on this sheet, so you cannot uncheck it." )
                        sub_txn ||= get_and_start_subtxn( doc )
                        set_rev_param_on_sheet( sheet, sheet_param, 1 )
                        #set_sheet_param_flag( sheet_param, "has_rev_clouds", true )
                    end
                end
            end
            # If none of our rev-named parameters was changed on the sheet, then check if Revisions on Sheet has changed.
            # If Revisions on Sheet has not changed either, then this is some change to the sheet that we don't care about,
            # and Execute() has only been called because we have to use GetChangeTypeAny below due to 2014 API lacking the ability
            # to detect changes to Revisions on Sheet as a parameter-specific trigger.
            if not changed_param
                dbgp "ANY change for: #{sheet.Name}, Type: #{sheet.GetType().Name}"

                # User may have changed the Revisions on Sheet. Compare those values to the params and update any params.
                rev_ids = sheet.GetAllProjectRevisionIds()
                dbgp "All current revs for sheet: #{rev_ids.to_s}"
                param_list.each do |param|
                    sheet_param = sheet.get_Parameter( param.Definition.Name )
                    is_checked = sheet_param.AsValueString() == "Yes"
                    #rev = revision_from_name( doc, param.Definition.Name )
                    rev = revs_map[param.Definition.Name]
                    if is_checked and (not sheet_contains_rev_id( sheet, rev.Id ))
                        # The param is checked but the revision isn't in Revisions on Sheet, so uncheck the param.
                        # We have to know whether there was a changed rev cloud here.
                        # If there was NOT a rev cloud,
                        # then the user unchecked the Revisions on Sheet checkbox, so uncheck the param.
                        # If there WAS a rev cloud,
                        # then the user deleted a rev cloud, and if the manually checked flag is set, the
                        # rev should remain checked, so instead of unchecking the param, add the rev back in.
                        if not sheet_param_flag_value_is_set( sheet_param, "has_rev_clouds" )
                            dbgp "Unchecking checkbox for param #{param.Definition.Name}"
                            sub_txn ||= get_and_start_subtxn( doc )
                            set_rev_param_on_sheet( sheet, sheet_param, 0 )
                            #set_sheet_param_flag( sheet_param, "manually_checked", false )
                        else
                            if sheet_param_flag_value_is_set( sheet_param, "manually_checked" )
                                dbgp "Re-adding the rev for the manually checked param #{param.Definition.Name}"
                                sub_txn ||= get_and_start_subtxn( doc )
                                add_rev_id_to_sheet( sheet, rev.Id, sub_txn )
                                set_rev_update_to_force( sheet, rev.Id )
                                #set_sheet_param_flag( sheet_param, "has_rev_clouds", false )
                            else    
                                dbgp "Unchecking checkbox for deleted rev cloud for param #{param.Definition.Name}"
                                sub_txn ||= get_and_start_subtxn( doc )
                                set_rev_param_on_sheet( sheet, sheet_param, 0 )
                                #set_sheet_param_flag( sheet_param, "has_rev_clouds", false )
                            end
                        end
                    elsif (not is_checked) and sheet_contains_rev_id( sheet, rev.Id )
                        # The param is NOT checked but the revision IS in Revisions on Sheet, so check the param.
                        dbgp "Turning on checkbox for param #{param.Definition.Name}"
                        sub_txn ||= get_and_start_subtxn( doc )
                        set_rev_param_on_sheet( sheet, sheet_param, 1 )
                        # If there are rev clouds for the revision, remember that by setting the flag.
                        # If there are no rev clouds for the revision, then set the manually checked flag
                        # (b/c the user checked the checkbox in Revisions on Sheet).
                        if sheet_has_rev_clouds_for_revision( sheet, rev.Id )
                            #set_sheet_param_flag( sheet_param, "manually_checked", false )
                            #set_sheet_param_flag( sheet_param, "has_rev_clouds", true )
                        else
                            #set_sheet_param_flag( sheet_param, "manually_checked", true )
                            #set_sheet_param_flag( sheet_param, "has_rev_clouds", false )
                        end
                    end
                end
            end
        end
        if sub_txn
            dbgp "Committing sub_txn"
            sub_txn.Commit()
        end
        dbgp "Exiting sheet change updater"
        rescue Exception => e
            report_error( "Exception" )
            report_error( e.to_s )
            raise
        end
    end


    #----------------
    def set_sheet_param_flag( sheet_param, flag_name, bool_value )
        # This was part of the effort to work around RevisionsOnSheet deficiencies,
        # but 2014 Update 1 fixed them, so this is all commented out for now.
        #manually_checked_entity = OPX::SheetRevParamEntity.create()
        #manually_checked_entity.Set( flag_name, bool_value )
        #sheet_param.SetEntity( manually_checked_entity )
    end

    #----------------
    def sheet_param_flag_value_is_set( sheet_param, flag_name )
        # This was part of the effort to work around RevisionsOnSheet deficiencies,
        # but 2014 Update 1 fixed them, so this is all commented out for now.
        flag_value = false
        #entity = sheet_param.GetEntity( OPX::SheetRevParamEntity.schema_def )
        #if entity.IsValid()
        #    flag_value = entity.method(:Get).of(System::Boolean).call( flag_name )
        #end
        return flag_value
    end

    #----------------
    def set_rev_update_to_force( sheet, rev_id )
        @rev_updates_to_force[sheet] = rev_id
        @rev_updates_exist = true
    end

    #----------------
    def GetAdditionalInformation()
        return "OPX Sheet Revision Change updater: detects a change to a Sheet's Revisions on Sheet and updates the field of the same name that's linked to the Sheet Log."
    end

    #----------------
    def GetChangePriority()
        # This has to be a lower priority than the Revision Updater, or the GetChangeTypeAny trigger below causes a blow-up
        # of this updater before Execute() has even been entered. Nasty Revit bug, but fortunately this solves it.
        return ChangePriority.Annotations
        #return ChangePriority.Views
    end

    #----------------
    def GetUpdaterId()
        return @updater_id
    end
    
    #----------------
    def GetUpdaterName()
        return @@updater_name
    end

    #------------------
    def add_rev_named_param_triggers_for_doc( doc )

        # Get a list of all the revisions. The sheet parameters having names that match revision names will be change triggers.
        desc_param = nil
        revs = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Revisions)

        # To get the revision-named parameters from sheets that will be monitored for changes,
        # there has to be at least one sheet in the project that has those parameters in it. Get it.
        sheet = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Sheets).FirstElement()
        dbgp "first sheet is #{sheet.Name}"

        # Any sheet element can have a Revision on Sheet change occur.
        sheets_filter = ElementCategoryFilter.new( BuiltInCategory.OST_Sheets )

        # Go through each revision, get its name, get the sheet parameter of the same name, and add a trigger on that parameter.
        # The trigger will fire when a user checks or unchecks our created sheet parameters that are named the same as a revision. 
        revs.each do |rev|
            rev_name = rev.get_Parameter( $revision_name_param_name ).AsString()
            dbgp "Rev name: #{rev_name}", 2
            sheet_rev_param = sheet.get_Parameter( rev_name )
            if not sheet_rev_param
                dbgp "Adding missing sheet revision param '#{rev_name}'"
                sched = schedule_from_name( doc, $sheet_issue_log_name )
                # Tried to call add_new_field_to_sheet_list(), but it triggers DocumentChanged events, which, from inside the DocumentCreated event,
                # caused problems that weren't resolved by sub_txn or other workarounds. So, pre-existing revisions that aren't in the param list
                # of a newly created or opened document won't have their checkboxes explicitly set to 'No' from the start.
                add_field_to_sheet_list( sched, rev_name, ParameterType.YesNo )
                sheet_rev_param = sheet.get_Parameter( rev_name )
                #TaskDialog.Show( "No '#{rev_name}' Sheet Parameter", "There is no parameter named #{rev_name}. The sheet revision automation can't work without a YesNo parameter named '#{rev_name}'." )
            end

            # Add trigger for this parameter name.
            dbgp "Adding sheet param trigger for '#{rev_name}'", 1
            begin
            UpdaterRegistry.AddTrigger( @updater_id, sheets_filter, Element.GetChangeTypeParameter( sheet_rev_param ) )
            rescue Exception => e
                report_error( "Exception" )
                report_error( e.to_s )
                raise
            end
        end
    end

    #------------------
    def on_doc_created_add_rev_param_triggers_handler( sender, args )
        # This will run on every project open, so that the rev-named params for that doc have triggers.
begin
        dbgp "In doc created handler, status is #{args.Status}"
        if args.Status == RevitAPIEventStatus.Succeeded
            doc = args.Document
            dbgp "In doc created handler for doc #{doc.Title}"
            add_rev_named_param_triggers_for_doc( doc )
        end
rescue Exception => e
    report_error( "Exception" )
    report_error( e.to_s )
    raise
end
    end

    #------------------
    def on_doc_opened_add_rev_param_triggers_handler( sender, args )
        # This will run on every project open, so that the rev-named params for that doc have triggers.
        dbgp "In doc opened handler, status is #{args.Status}"
        if args.Status == RevitAPIEventStatus.Succeeded
            doc = args.Document
            dbgp "In doc opened handler for doc #{doc.Title}"
            add_rev_named_param_triggers_for_doc( doc )
        end
    end

    #------------------
    def on_doc_changed_new_revision_handler( sender, args )
        begin
            dbgp "In the doc changed handler"
            # If this was the creation of a new revision (or the rename of a revision), rather than a sheet rev change, add a trigger for the rev-named param and get out.
            doc = args.GetDocument() 
            mod_ids = args.GetModifiedElementIds( ElementCategoryFilter.new(BuiltInCategory.OST_Revisions) )
            mod_ids.each do |mod_id|
                e = doc.GetElement( mod_id )
                # This already-existing rev was modified. There is no way to know what is modified, as the actions in the RevisionUpdater
                # are already complete, so if we get here, it MAY be because the name of a revision changed.
                # It could also have been a date change for the revision -- can't know now.
                # So, remove all of the triggers and re-add them.
                dbgp "Doc changed handler got modified ID #{mod_id.IntegerValue}, #{e.Name}, #{e.GetType().Name}, #{e.get_Parameter( $revision_name_param_name ) != nil ? e.get_Parameter( $revision_name_param_name ).AsString() : ''}, #{e.Category != nil ? e.Category.Name : ''}"
                UpdaterRegistry.RemoveAllTriggers( @updater_id )
                add_rev_named_param_triggers_for_doc( doc )
                sheets_filter = ElementCategoryFilter.new( BuiltInCategory.OST_Sheets )
                UpdaterRegistry.AddTrigger( @updater_id, sheets_filter, Element.GetChangeTypeAny() )
            end
            
            new_ids = args.GetAddedElementIds( ElementCategoryFilter.new(BuiltInCategory.OST_Revisions) )
            new_ids.each do |new_id|
                dbgp "New rev added, need to add trigger for sheet rev-named param"
                new_element = doc.GetElement(new_id)
                rev_name = new_element.get_Parameter( $revision_name_param_name ).AsString()
                dbgp "Rev param name is #{rev_name}"
                first_sheet = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Sheets).FirstElement()
                sheets_filter = ElementCategoryFilter.new( BuiltInCategory.OST_Sheets )
                sheet_rev_param = first_sheet.get_Parameter( rev_name )
                dbgp "Adding trigger for new rev param #{rev_name}"
                UpdaterRegistry.AddTrigger( @updater_id, sheets_filter, Element.GetChangeTypeParameter( sheet_rev_param ) )
            end
        rescue Exception => e
            report_error( "Exception" )
            report_error( e.to_s )
            raise
        end
    end

    #------------------
    # Used by the on_idle method below. Does and un-does a revision update to force the titleblock graphics to update.
    def force_revision_schedule_update( sheet, rev_id )
        if sheet_contains_rev_id( sheet, rev_id )
            txn = Transaction.new( sheet.Document, "OPX force rev update" )
            txn.Start()
            dbgp "Removing and re-adding rev #{rev_id.IntegerValue}"
            remove_rev_id_from_sheet( sheet, rev_id, txn )
            add_rev_id_to_sheet( sheet, rev_id, txn )
            txn.Commit()
        else
            # Un-add and re-add must be separate txns to work around the titleblock not updating on removal of the last unchecked rev. 
            dbgp "Adding and re-removing rev #{rev_id.IntegerValue}"
            add_rev_id_to_sheet( sheet, rev_id )
            remove_rev_id_from_sheet( sheet, rev_id )
        end
    end

	#------------------
    def on_idle_force_revision_schedule_update_handler( sender, args )
        # This flag is a noticeable performance improvement over using .each as the flag.
        if not @rev_updates_exist
            return
        end
        @rev_updates_exist = false

        # Iterate through the hash of sheets that need to have a rev update forced.
        # Forcing a rev update is the only way to get the titleblock revision schedule to update.
        @rev_updates_to_force.each do | sheet, rev_id |
            begin
                dbgp "Sheet #{sheet.Id.IntegerValue}, force update using rev #{rev_id.IntegerValue}"
                force_revision_schedule_update( sheet, rev_id )
            rescue Exception => e
                report_error( "Exception" )
                report_error( e.to_s )
                @rev_updates_to_force.clear
                raise
            end
        end
        @rev_updates_to_force.clear
    end

    #------------------
    def self.register_updater( ui_app, app, doc = nil )
        begin
        dbgp "Register SheetRevisionChangeUpdater with ActiveAddInId #{app.ActiveAddInId.GetGUID().to_s}"
    
        updater = SheetRevisionChangeUpdater.new( app.ActiveAddInId )
        dbgp "Updater id is #{updater.GetUpdaterId().GetGUID()}"
        UpdaterRegistry.RegisterUpdater( updater )
    
        # For RevitRubyShell work with already-opened project. Doc will be nil when the OnStartup installs the macro.
        if doc
            updater.add_rev_named_param_triggers_for_doc( doc )
        end
    
        # Sigh. 2014 API doesn't trigger on Revision on Sheet changes. Have to use GetChangeTypeAny.
        # Would have preferred the commented-out trigger that only triggered on changes to the Revisions on Sheet parameter.
        #UpdaterRegistry.AddTrigger( updater.GetUpdaterId(), sheets_filter, Element.GetChangeTypeParameter( revisions_on_sheet_param ) )
    
        # ARRRGH! When a user creates a new revision with the Revision Updater in place, this trigger is causing a blow-up in this updater
        # PRIOR TO the Execute() method even getting called. Solved by lowering the priority of this updater to Annotations (see above),
        # which is below the Views priority of the Revision Updater. That fixes it, for whatever reason.
        sheets_filter = ElementCategoryFilter.new( BuiltInCategory.OST_Sheets )
        UpdaterRegistry.AddTrigger( updater.GetUpdaterId(), sheets_filter, Element.GetChangeTypeAny() )
    
        # Add an event listener for doc changes that will allow the adding of a trigger for new rev-named params when a rev is created.
        # AddTrigger cannot be called from within Execute().
        dbgp "Register new rev DocumentCreated handler using method #{updater.method(:on_doc_created_add_rev_param_triggers_handler)}"
        app.DocumentCreated.Add( updater.method(:on_doc_created_add_rev_param_triggers_handler) )
        dbgp "Register new rev DocumentOpened handler"
        app.DocumentOpened.Add( updater.method(:on_doc_opened_add_rev_param_triggers_handler) )
        dbgp "Register new rev DocumentChanged handler"
        app.DocumentChanged.Add( updater.method(:on_doc_changed_new_revision_handler) )
        dbgp "Register force rev update Idling handler"
        ui_app.Idling.Add( updater.method(:on_idle_force_revision_schedule_update_handler) )
    
        rescue Exception => e
            report_error( "Exception" )
            report_error( e.to_s )
            raise
        end
    
        return updater
    end

    #---------------
    def self.unregister_updater( ui_app, app, updater = nil )
        begin
            updater ||= SheetRevisionChangeUpdater.new( app.ActiveAddInId ) 
            dbgp "UN-register SheetRevisionChangeUpdater with GUID #{updater.GetUpdaterId().GetGUID()}, ActiveAddInId #{app.ActiveAddInId.GetGUID().to_s}"
            #updater = SheetRevisionChangeUpdater.new( app.ActiveAddInId )
            UpdaterRegistry.UnregisterUpdater(updater.GetUpdaterId())
    
            dbgp "Un-reg the event handlers"
            # These calls do not work. The methods do not get removed from the handler.
            app.DocumentCreated.Remove( updater.method(:on_doc_created_add_rev_param_triggers_handler) )
            app.DocumentOpened.Remove( updater.method(:on_doc_opened_add_rev_param_triggers_handler) )
            app.DocumentChanged.Remove( updater.method(:on_doc_changed_new_revision_handler) )
            ui_app.Idling.Remove( updater.method(:on_idle_force_revision_schedule_update_handler) )
        rescue Exception => e
            report_error( "Exception" )
            report_error( e.to_s )
            raise
        end
    
    end

end


end

