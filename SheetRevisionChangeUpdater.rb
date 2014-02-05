load_assembly 'RevitAPI'
load_assembly 'RevitAPIUI'
include Autodesk::Revit
include Autodesk::Revit::UI
include Autodesk::Revit::DB
include Autodesk::Revit::DB::Architecture
include Autodesk::Revit::DB::Events

$revision_name_param_name = "Revision Description"

# ThisApplication.rb sets the env variable. Otherwise, I'm working in RevitRubyShell and working from my repo dir.
revitrubyshell_file_load_path = 'S:\\OPX_StuffFOLDERS\\SoftwareDev\\Revit\\RevisionAndSheetLogUpdater'
file_load_path = ENV.fetch("opx_file_load_path")
file_load_path ||= revitrubyshell_file_load_path
$LOAD_PATH.unshift(file_load_path)
$is_revitrubyshell = ( file_load_path == revitrubyshell_file_load_path )

require 'dbgp'

dbgp "Loading sheetRevisionChangeUpdater.rb"

require 'updateSheetRevisions'

#------------------------------------
# Updater that is triggered when checking a Revision on Sheet
#------------------------------------
class SheetRevisionChangeUpdater
    include Autodesk::Revit::DB::IUpdater

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
                dbgp "Param id is #{param.Id}"
                dbgp "Param name is #{param.Definition.name}"
                if data.IsChangeTriggered( id, Element.GetChangeTypeParameter( param ) )
                    dbgp "PARAMETER change for: #{sheet.Name}, Param: #{param.Definition.Name}"
                    changed_param = param
                    sheetParam = sheet.get_Parameter( param.Definition.Name )
                    is_checked = sheetParam.AsValueString() == "Yes"
                    dbgp "#{param.Definition.Name} = #{sheetParam.AsValueString()}, is_checked = #{is_checked}"
                    #rev = revision_from_name( doc, param.Definition.Name )
                    rev = revs_map[param.Definition.Name]
                    dbgp "rev id is #{rev.Id}"
                    if ( is_checked and (not sheet_contains_rev_id( sheet, rev.Id )) )
                        # The param is checked but the revision isn't in Revisions on Sheet, so add the rev to Revisions on Sheet.
                        dbgp "sub_txn is #{sub_txn.to_s}"
                        sub_txn ||= get_and_start_subtxn( doc )
                        dbgp "sub_txn is #{sub_txn.to_s}"
                        add_rev_id_to_sheet( sheet, rev.Id, sub_txn )
                        set_rev_update_to_force( sheet, rev.Id )
                    elsif ( (not is_checked) and sheet_contains_removable_rev_id( sheet, rev.Id ) )
                        # The param is NOT checked but the revision IS in Revisions on Sheet and removable, so remove the rev from Revisions on Sheet.
                        sub_txn ||= get_and_start_subtxn( doc )
                        remove_rev_id_from_sheet( sheet, rev.Id, sub_txn )
                        set_rev_update_to_force( sheet, rev.Id )
                    elsif ( (not is_checked) and sheet_contains_rev_id( sheet, rev.Id ) )
                        # The param is NOT checked, but the revision IS in Revisions on Sheet and is NOT removable, so recheck the param.
                        # It can't be marked unchecked because there is a revision cloud revision for this rev name.
                        sub_txn ||= get_and_start_subtxn( doc )
                        #sheetParam.Set( 1 )
                        set_rev_param_on_sheet( sheet, sheetParam, 1 )
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
                    sheetParam = sheet.get_Parameter( param.Definition.Name )
                    is_checked = sheetParam.AsValueString() == "Yes"
                    #rev = revision_from_name( doc, param.Definition.Name )
                    rev = revs_map[param.Definition.Name]
                    if is_checked and not sheet_contains_rev_id( sheet, rev.Id )
                        # The param is checked but the revision isn't in Revisions on Sheet, so uncheck the param.
                        dbgp "Unchecking checkbox for param #{param.Definition.Name}"
                        sub_txn ||= get_and_start_subtxn( doc )
                        #sheetParam.Set( 0 )
                        set_rev_param_on_sheet( sheet, sheetParam, 0 )
                    elsif not is_checked and sheet_contains_rev_id( sheet, rev.Id )
                        # The param is NOT checked but the revision IS in Revisions on Sheet, so check the param.
                        dbgp "Turning on checkbox for param #{param.Definition.Name}"
                        sub_txn ||= get_and_start_subtxn( doc )
                        #sheetParam.Set( 1 )
                        set_rev_param_on_sheet( sheet, sheetParam, 1 )
                    end
                end
            end
        end
        if sub_txn
            dbgp "Committing sub_txn"
            sub_txn.Commit()
        end
        rescue Exception => e
            report_error( "Exception" )
            report_error( e.to_s )
            raise
        end
    end

    #----------------
    def set_rev_update_to_force( sheet, rev_id )
        @rev_updates_to_force[sheet] = rev_id
        @rev_updates_exist = true
    end

    #----------------
    def GetAdditionalInformation()
        return "Sheet Revision Change updater: detects a change to a Sheet's Revisions on Sheet and updates the field of the same name that's linked to the Sheet Log."
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
        return "Sheet Revision Change Updater"
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
            dbgp "Adding sheet param trigger for '#{rev_name}'", 2
            UpdaterRegistry.AddTrigger( @updater_id, sheets_filter, Element.GetChangeTypeParameter( sheet_rev_param ) )
        end
    end

    #------------------
    def on_doc_created_add_rev_param_triggers_handler( sender, args )
        # This will run on every project open, so that the rev-named params for that doc have triggers.
        dbgp "In doc created handler, status is #{args.Status}"
        if args.Status == RevitAPIEventStatus.Succeeded
            doc = args.Document
            dbgp "In doc created handler for doc #{doc.Title}"
            add_rev_named_param_triggers_for_doc( doc )
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
            # If this was the creation of a new revision, rather than a sheet rev change, add a trigger for the rev-named param and get out.
            doc = args.GetDocument() 
            if $debug_level > 1
                new_ids = args.GetModifiedElementIds()
                new_ids.each do |new_id|
                    e = doc.GetElement( new_id )
                    dbgp "Doc changed handler modified ID #{new_id.IntegerValue}, #{e.Name}, #{e.GetType().Name}, #{e.get_Parameter( $revision_name_param_name ) != nil ? e.get_Parameter( $revision_name_param_name ).AsString() : ''}, #{e.Category != nil ? e.Category.Name : ''}"
                end
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
    def on_idle_force_revision_schedule_update_handler( sender, args )
        # This flag is a noticeable performance improvement over using .each as the flag.
        if not @rev_updates_exist
            return
        end
        @rev_updates_exist = false

        # Iterate through the hash of sheets that need to have a rev update forced.
        @rev_updates_to_force.each do | sheet, rev_id |
            begin
                dbgp "Sheet #{sheet.Id.IntegerValue}, force update using rev #{rev_id.IntegerValue}"
                txn = Transaction.new( sheet.Document, "OPX force rev update" )
                txn.Start()
                if sheet_contains_rev_id( sheet, rev_id )
                    remove_rev_id_from_sheet( sheet, rev_id, txn )
                    add_rev_id_to_sheet( sheet, rev_id, txn )
                else
                    add_rev_id_to_sheet( sheet, rev_id, txn )
                    remove_rev_id_from_sheet( sheet, rev_id, txn )
                end
                txn.Commit()
            rescue Exception => e
                report_error( "Exception" )
                report_error( e.to_s )
                raise
            end
        end
    end

end


#------------------
def sheets_register_updater( ui_app, app, doc = nil )
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
    dbgp "Register new rev DocumentCreated handler"
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
def sheets_unregister_updater( ui_app, app, updater = nil )
    begin
        updater ||= $sheets_updater 
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

#$sheets_updater = sheets_register_updater( _app )
#sheets_unregister_updater( _app, $sheets_updater )


