# UpdateSheetRevisions.rb
# ThisApplication.rb sets the env variable. Otherwise, I'm working in RevitRubyShell and working from my repo dir.
revitrubyshell_file_load_path = 'S:\\OPX_StuffFOLDERS\\SoftwareDev\\Revit\\opxRevisionAndSheetLogUpdater'
file_load_path = ENV.fetch("opx_file_load_path")
file_load_path ||= revitrubyshell_file_load_path
$LOAD_PATH.unshift(file_load_path)
$is_revitrubyshell = ( file_load_path == revitrubyshell_file_load_path )

require 'dbgp'
include OPX
dbgp "Loading updateSheetRevisions.rb"

load_assembly 'RevitAPI'
load_assembly 'RevitAPIUI'
include Autodesk::Revit
include Autodesk::Revit::UI
include Autodesk::Revit::DB
include Autodesk::Revit::DB::Architecture

module OPX

$revision_name_param_name = "Revision Description"
$rev_named_params_param_group = BuiltInParameterGroup.PG_GENERAL

#$sheet_list_category_id = -2003100  # CategoryId for sheet lists. Can't find this defined anywhere, just seems to be the case. FYI.
$sheet_issue_log_name = "000 SHEET ISSUE LOG"
#$sheet_issue_log_name = "BAD SHEET ISSUE LOG NAME"
$sheet_issue_log = nil  # Global variable gets set on first access of sheet_issue_log(), for performance.

SHEET_ISSUE_LOG_NOT_FOUND = "Sheet Issue Log not found"

#---------------------------------------------
# Create and start a txn if one isn't started.
# If one is created here, return true for doCommit so that
# the commit will be made at this same level.
def start_txn_if_none_exists( doc, txn )
	txn_created = false
	if not txn
		txn = Transaction.new( doc, "OPX Txn" )
		txn.Start()
		txn_created = true
	end
	return txn, txn_created
end	

#---------------------------------------------
# Commit the txn if this is the level at which it was created.
# Leave the txn open if this isn't the level at which it was created.
def commit_txn_if_started_here( txn, txn_created )
	if txn_created
		txn.Commit()
		return true
	end
	return false
end	

#---------------------------------------------
# In Execute() of Updaters, only subtransactions can be used.
# Get and start a subtxn in one go.
def get_and_start_subtxn( doc )
    sub_txn = SubTransaction.new( doc )
    sub_txn.Start()
    return sub_txn
end 

#---------------------------------------------
def rev_named_params_list( doc )
    # Get the list of all params that are named after revs.
    # This requires that there be at least one sheet in the project.
    revs = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Revisions)
    first_sheet = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Sheets).FirstElement()
    param_list = Array.new
    revs.each do |rev|
        rev_name = rev.get_Parameter( $revision_name_param_name ).AsString()
        rev_named_param = first_sheet.get_Parameter( rev_name )
        if not rev_named_param
        	# There should never be a missing rev-named param, because it should have been added already.
        	raise "Error: there is no sheet param for revision name #{rev_name}."
        end 
        param_list.push( rev_named_param )
        dbgp "Found param for rev name #{rev_name}", 2
    end
    dbgp "Param list size is : #{param_list.size}"
    return param_list
end

#---------------------------------------------
def sheet_param_from_name( doc, name )

    # This requires that there be at least one sheet in the project.
    return FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Sheets).FirstElement().get_Parameter( name )
end

#---------------------------------------------
def sheet_from_name( doc, name )
	sheet = nil
	sheets = FilteredElementCollector.new(doc).OfClass(ViewSheet.to_clr_type)
	sheets.each do |s|
		if s.name == name 
			sheet = s
			break			
		end
	end
	return sheet
end

#---------------------------------------------
def schedule_from_name( doc, name )
	sched = nil
	scheds = FilteredElementCollector.new(doc).OfClass(ViewSchedule.to_clr_type)
	scheds.each do |s|
		dbgp "#{s.name}, CategoryId=#{s.Definition.CategoryId}", 2
		if s.name == name 
			sched = s
			break			
		end
	end
	if not sched
		TaskDialog.Show( SHEET_ISSUE_LOG_NOT_FOUND, "There is no sheet log named #{name}." )
		raise SHEET_ISSUE_LOG_NOT_FOUND
	end
	return sched 
end

#---------------------------------------------
def sheet_issue_log( doc )
	$sheet_issue_log ||= schedule_from_name( doc, $sheet_issue_log_name )

	return $sheet_issue_log 
end

#---------------------------------------------
def schedule_field_from_name( sched, name )
	field = nil
	sched_def = sched.Definition
	sched_field_ids = sched_def.GetFieldOrder()
	sched_field_ids.each do |id|
		f = sched_def.GetField(id)
		dbgp "#{f.GetName()}, ParameterId=#{f.ParameterId}", 2
		if f.GetName() == name
			field = f
			break
		end
	end
	return field 
end

#---------------------------------------------
# Returns the first (and hopefully only) rev-named schedule field that doesn't have a corresponding rev.
def rev_param_not_matching_any_rev_name( sched )
	rev_param = nil
	revs_map = revisions_map_by_name( sched.Document )
	sched_def = sched.Definition
	sched_field_ids = sched_def.GetFieldOrder()
	sched_field_ids.each do |id|
		f = sched_def.GetField(id)
		fieldName = f.GetName()
		dbgp "#{fieldName}, ParameterId=#{f.ParameterId}", 2
		#if revision_from_name( sched.Document, fieldName ) == nil
		if revs_map[fieldName] == nil
			# Confirm that the field is a param in the param group that holds rev-named params.
			# Otherwise, it could be some non-rev-named param that a user added to the sheet issue log.
			r = sheet_param_from_name( sched.Document, fieldName )
			if r.Definition.ParameterGroup == $rev_named_params_param_group
				dbgp "field name '#{fieldName}' does not match any rev name and is in #{r.Definition.ParameterGroup.to_s}"
				rev_param = r
				break
			end
		end
	end
	return rev_param 
end

#---------------------------------------------
def schedulable_field_from_name( sched, name )
	field = nil
	doc = sched.Document
	sched_def = sched.Definition
	schedulable_fields = sched_def.GetSchedulableFields()
	schedulable_fields.each do |f|
		dbgp "#{f.GetName( doc )}, ParameterId=#{f.ParameterId}", 2
		if f.GetName( doc ) == name
			field = f
			break
		end
	end
	return field 
end

#---------------------------------------------
def revision_from_name( doc, name )
	rev = nil
	revs = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Revisions)
	revs.each do |r|
		rev_name = r.get_Parameter( $revision_name_param_name ).AsString()		
		dbgp "#{rev_name}, RevNumber=#{r.get_Parameter( "Revision Number" ).AsString()}", 2
		if rev_name == name
			rev = r
			dbgp "Returning rev element #{rev_name} from its name", 2
			break
		end
	end
	return rev 
end

#---------------------------------------------
# For performance, instead of calling revision_from_name a lot.
def revisions_map_by_name( doc )
	revs_map = Hash.new
	revs = FilteredElementCollector.new(doc).OfCategory(BuiltInCategory.OST_Revisions)
	revs.each do |r|
		rev_name = r.get_Parameter( $revision_name_param_name ).AsString()		
		revs_map[rev_name] = r
	end
	return revs_map
end

#---------------------------------------------
# This function doesn't work because GetCellText() is erroneously returning empty strings for everything except the header row of field names
# (which you'd think was in the SectionType.Header, but isn't -- it's the first row of SectionType.Body).
def row_and_column_of_param_in_schedule_body( sched, sheet, param )
	sheet_name = sheet.Name
	row = nil

	# Get the column number by getting the ordered index of non-hidden fields.
	# This avoids having to do a name comparison by the ColumnHeading value of the field.
	# This part of the function works.
	col = nil
	param_field = nil
	sched_def = sched.Definition
	sched_def.GetFieldOrder().each do |field_id|
		field = sched_def.GetField( field_id )
		if not field.IsHidden()
			col = col ? col + 1 : body_data.FirstColumnNumber
			dbgp "Matching param id #{param.Id} to col #{col}, #{field.ParameterId} -- #{field.ColumnHeading}"
			# Don't return a row and col if for some reason the user has hidden the field in question, since it's not visible in the table.
			if field.ParameterId == param.Id
				dbgp "Matched"
				param_field = field
				break
			end
		end
	end
	if param_field == nil
		return nil, nil
	end

	# Get the row by comparing the first column of the row to the sheet name.
	# This doesn't work, as explained above. There are no other sections (only Header and Body), the Header has nothing in its only row,
	# and the Body returns the correct number of rows, but every row is empty except the first row.
	body_data = sched.GetTableData().GetSectionData( SectionType.Body )
	sheet_name_col = body_data.FirstColumnNumber + 1
	(body_data.FirstRowNumber..body_data.LastRowNumber).each do |r|
		dbgp "Matching #{sheet_name} to row #{r} -- #{body_data.GetCellText( r, sheet_name_col  )}"
		if body_data.GetCellText( r, sheet_name_col ) == sheet_name
			dbgp "Matched"
			row = r
			break
		end
	end
	if row == nil
		return nil, nil
	end

	dbgp "Row, col of param are #{row}, #{col}"
	return row, col

end

#---------------------------------------------
def set_rev_param_on_sheet( sheet, param, value )
	param.Set( value )
	#sched = sheet_issue_log( sheet.Document )
	#row_and_column_of_param_in_schedule_body( sched, sheet, param )
end
	
#---------------------------------------------
def update_revisions_for_sheet( sheet, revs, txn = nil )
	txn, txn_created = start_txn_if_none_exists( sheet.Document, txn )

	sheet.SetAdditionalProjectRevisionIds( revs )

	commit_txn_if_started_here( txn, txn_created )
end

#---------------------------------------------
# Indicates whether a rev id is present for a sheet.
# If present, doesn't matter whether it's from a revision cloud or from a user addition.
def sheet_contains_rev_id( sheet, rev_id )
	revs = sheet.GetAllProjectRevisionIds()
	dbgp "Contains is #{revs.Contains( rev_id )}", 2
	return revs.Contains( rev_id )
end

#---------------------------------------------
# Indicates whether a rev id is present and manually removable for a sheet.
# It must be manually removable to return true, because an attempt will be made to manually remove it.
# You can't manually remove revision cloud revs.
def sheet_contains_removable_rev_id( sheet, rev_id )
	revs = sheet.GetAdditionalProjectRevisionIds()
	dbgp "Contains is #{revs.Contains( rev_id )}", 2
	return revs.Contains( rev_id )
end

#---------------------------------------------
def remove_rev_id_from_sheet( sheet, rev_id, txn = nil )
	txn, txn_created = start_txn_if_none_exists( sheet.Document, txn )

	# Get the array of revisions that can be changed by the user.
	# Revision cloud revisions are not changeable by the user and won't be in this list.
	revs = sheet.GetAdditionalProjectRevisionIds()
	dbgp "Removable revs: #{revs.to_s}"

	# Remove rev_id from array.
	revs.Remove( rev_id )
	dbgp "Editable revs after remove: #{revs.to_s}"

	# Saved the updated revisions array.
	update_revisions_for_sheet( sheet, revs, txn )
	# Odd. The GetAll below doesn't reflect the newly removed one. sub_txn doesn't show up until commit?
	revs = sheet.GetAllProjectRevisionIds()
	dbgp "All revs after save: #{revs.to_s}"

	commit_txn_if_started_here( txn, txn_created )
end

#---------------------------------------------
def add_rev_id_to_sheet( sheet, rev_id, txn = nil )
	txn, txn_created = start_txn_if_none_exists( sheet.Document, txn )

	# Get the array of revisions that can be changed by the user.
	# Revision cloud revisions are not changeable by the user and won't be in this list.
	revs = sheet.GetAdditionalProjectRevisionIds()
	dbgp "Current editable revs: #{revs.to_s}, count = #{revs.Count()}"

	all_revs = sheet.GetAllProjectRevisionIds()
	dbgp "All revs before save: #{all_revs.to_s}"

	# Add rev_id to array.
	revs.Add( rev_id )
	dbgp "Editable revs after add: #{revs.to_s}"

	# Saved the updated revisions array.
	update_revisions_for_sheet( sheet, revs, txn )
	# Odd. The GetAll below doesn't reflect the newly added one. sub_txn doesn't show up until commit?
	all_revs = sheet.GetAllProjectRevisionIds()
	dbgp "All revs after save: #{all_revs.to_s}"

	commit_txn_if_started_here( txn, txn_created )
end


#---------------------------------------------
def create_shared_param_def_with_temp_file( doc, param_name, param_type )
	new_param_def = nil

	# Create a temp shared parameter file.
	main_app = doc.Application
	original_shared_file = main_app.SharedParametersFilename
    temp_file_name = "#{System::IO::Path.GetTempFileName()}"
    main_app.SharedParametersFilename = temp_file_name

    # Create a new shared parameter.
    shared_param_file = main_app.OpenSharedParameterFile()
    temp_def_group = shared_param_file.Groups.Create("TemporaryDefinitionGroup")
    new_param_def = temp_def_group.Definitions.Create( param_name, param_type, true )

    # Get rid of the temp shared parameter file.
    main_app.SharedParametersFilename = original_shared_file
    System::IO::File.Delete(temp_file_name)

    return new_param_def
end

#---------------------------------------------
def add_project_parameter_to_sheets( doc, param_name, param_type, txn = nil )
	txn, txn_created = start_txn_if_none_exists( doc, txn )

	main_app = doc.Application

    # Create a shared parameter definition for the parameter being deleted.
	new_param_def = create_shared_param_def_with_temp_file( doc, param_name, param_type )

    # Create the set of categories (hard-coded to Sheets, in this case) to which the new param will be bound (i.e., added).
	categories = main_app.Create.NewCategorySet()
	category = doc.Settings.Categories.Item(BuiltInCategory.OST_Sheets)
	categories.Insert( category )

	# Bind the new parameter to the categories (Sheets) as an instance binding.
	# (every instance of Sheet will have a different value for the new param).
	instance_binding = main_app.Create.NewInstanceBinding(categories)
	binding_map = doc.ParameterBindings
	binding_map.Insert( new_param_def, instance_binding, $rev_named_params_param_group )

	commit_txn_if_started_here( txn, txn_created )
end

#---------------------------------------------
def add_field_to_sheet_list( sched, param_name, param_type, txn = nil, atIndex = nil )
	# Start a transaction.
	txn, txn_created = start_txn_if_none_exists( sched.Document, txn )

	# Add the parameter to the Sheets.
	dbgp "Add #{param_name} parameter to Sheets"
	add_project_parameter_to_sheets( sched.Document, param_name, param_type, txn )
	
	# Get the schedulable field that now exists for the newly added parameter.
	field_to_add = schedulable_field_from_name( sched, param_name )
	
	# Add the field to the sheet log. It will show up as a column in the sheet log.
	dbgp "Add #{param_name} field to sheet log"
	sched_def = sched.Definition
	added_field = atIndex == nil ? sched_def.AddField( field_to_add ) : sched_def.InsertField( field_to_add, atIndex )

	# Format the field.
	field_style = added_field.GetStyle()
	field_style.set_FontHorizontalAlignment( HorizontalAlignmentStyle.Center )
	added_field.SetStyle( field_style )

	# Commit the transaction.
	commit_txn_if_started_here( txn, txn_created )

	return added_field
end

#---------------------------------------------
# When adding a new param field, also explicitly set the value to 0 in every sheet to avoid the "ghost checkbox == not checked" UI.
def add_new_field_to_sheet_list( sched, param_name, param_type, txn = nil, atIndex = nil )
	added_field = add_field_to_sheet_list( sched, param_name, param_type, txn, atIndex )
    # Set the value of the new rev-named param to "No" in every sheet, to work around the Revit 3-valued-checkbox UI unpleasantness.
    sheets = FilteredElementCollector.new(sched.Document).OfCategory(BuiltInCategory.OST_Sheets)
    sheets.each do |sheet|
        #dbgp "Initializing param #{new_rev_name} (as 'No') for sheet #{sheet.Name}", 2
        set_rev_param_on_sheet( sheet, sheet.get_Parameter( param_name ), 0 )
    end

	return added_field
end

#---------------------------------------------
def remove_field_from_sheet_list( sched, param_name, txn = nil )
	# Start a transaction.
	txn, txn_created = start_txn_if_none_exists( sched.Document, txn )

	# Get the schedule field that exists for the schedule.
	dbgp "Remove #{param_name} from the sheet log"
	sched_def = sched.Definition
	field_to_remove = schedule_field_from_name( sched, param_name )
	sched_def.RemoveField( field_to_remove.FieldId )
	
	# Commit the transaction.
	commit_txn_if_started_here( txn, txn_created )
end

#---------------------------------------------
def delete_shared_parameter( sched, param, txn = nil )
	# Start a transaction.
	txn, txn_created = start_txn_if_none_exists( sched.Document, txn )

	# Remove the parameter from the project.
	dbgp "Delete parameter #{param.Definition.Name}"
	binding_map = sched.Document.ParameterBindings
	binding_map.Remove( param.Definition )

	# Commit the transaction.
	commit_txn_if_started_here( txn, txn_created )
end

#---------------------------------------------
def sheet_has_rev_clouds_for_revision( sheet, rev_id )
	# For now, just see if this rev is manually removable.
	# NOT being removable means there ARE rev clouds for this revision.
	return (not sheet_contains_removable_rev_id( sheet, rev_id ))
end

#--------------
#--------------
#--------------

# You can't manipulate Revisions on Sheet this way. 2014 API introduced Get/SetAdditionalProjectRevisionIds. 
#sheet = sheet_from_name( doc, "PROJECT INFO" )
#paramsMap = sheet.ParametersMap
#param = paramsMap.Item("Revisions on Sheet")


end