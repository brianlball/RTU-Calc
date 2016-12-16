# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

# start the measure
class CreateVariableSpeedRTU < OpenStudio::Ruleset::ModelUserScript

  # human readable name
  def name
    return "Create Variable Speed RTU"
  end

  # human readable description
  def description
    return "This measure examines the existing HVAC system(s) present in the current OpenStudio model. If a constant-speed system is found, the user can opt to have the measure replace that system with a variable-speed RTU. 'Variable speed' in this case means that the compressor will be operated using either two or four stages (user's choice). The user can choose between using a gas heating coil, or a direct-expansion (DX) heating coil. Additionally, the user is able to enter the EER (cooling) and COP (heating) values for each DX stage. This measure allows users to easily identify the impact of improved part-load efficiency."
  end

  # human readable description of modeling approach
  def modeler_description
    return "This measure loops through the existing airloops, looking for loops that have a constant speed fan. (Note that if an object such as an AirloopHVAC:UnitarySystem is present in the model, that the measure will NOT identify that loop as either constant- or variable-speed, since the fan is located inside the UnitarySystem object.) The user can designate which constant-speed airloop they'd like to apply the measure to, or opt to apply the measure to all airloops. The measure then replaces the supply components on the airloop with an AirloopHVAC:UnitarySystem object. Any DX coils added to the UnitarySystem object are of the type CoilCoolingDXMultiSpeed / CoilHeatingDXMultiSpeed, with the number of stages set to either two or four, depending on user input. If the user opts for a gas furnace, an 80% efficient CoilHeatingGas object is added. Fan properties (pressure rise and total efficiency) are transferred automatically from the existing (but deleted) constant speed fan to the new variable-speed fan. Currently, this measure is only applicable to the Standalone Retail DOE Prototype building model, but it has been structured to facilitate expansion to other models with a minimum of effort."
  end
  
  def airloop_chooser(model)
    air_loop_handles = OpenStudio::StringVector.new
    air_loop_display_names = OpenStudio::StringVector.new
    #putting air loop names into hash
    air_loop_args = model.getAirLoopHVACs
    air_loop_args_hash = {}
    air_loop_args.each do |air_loop_arg|
      air_loop_args_hash[air_loop_arg.name.to_s] = air_loop_arg
    end

    #looping through sorted hash of air loops
    air_loop_args_hash.sort.map do |air_loop_name,air_loop|
      #check airloop name not end in SAC
      if air_loop_name[-4,4] != " SAC"
        #find airterminals
        air_loop.demandComponents.each do |demand_comp|
          if demand_comp.to_AirTerminalSingleDuctUncontrolled.is_initialized
            #check all supply components
            found_good = false
            found_bad = false
            air_loop.supplyComponents.each do |sc|
              if sc.to_CoilHeatingGas.is_initialized || sc.to_CoilHeatingDXSingleSpeed.is_initialized
                found_good = true
              end
              if sc.to_CoilHeatingWater.is_initialized || sc.to_CoilHeatingWaterToAirHeatPumpEquationFit.is_initialized || sc.to_CoilCoolingWater.is_initialized || sc.to_CoilCoolingWaterToAirHeatPumpEquationFit.is_initialized
                found_bad = true
              end
              if sc.to_AirLoopHVACUnitaryHeatPumpAirToAir.is_initialized
                cc = sc.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.coolingCoil
                hc = sc.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.heatingCoil
                if hc.to_CoilHeatingGas.is_initialized || hc.to_CoilHeatingDXSingleSpeed.is_initialized
                  found_good = true
                end
                if hc.to_CoilHeatingWater.is_initialized || hc.to_CoilHeatingWaterToAirHeatPumpEquationFit.is_initialized || cc.to_CoilCoolingWater.is_initialized || cc.to_CoilCoolingWaterToAirHeatPumpEquationFit.is_initialized
                  found_bad = true
                end
              end
            end
            #if good is true and bad is false
            if (found_good == true && found_bad == false)
              air_loop_handles << air_loop.handle.to_s
              air_loop_display_names << air_loop_name
            end
          end
        end
      end  # name check
    end
    return air_loop_display_names, air_loop_handles
  end
  
  def number_heatcoils(air_loop)
    #loop through supply components and count heating coils
    num_coils = 0
    air_loop.supplyComponents.each do |sc|
      if sc.to_CoilHeatingGas.is_initialized || sc.to_CoilHeatingDXSingleSpeed.is_initialized || sc.to_CoilHeatingElectric.is_initialized
        num_coils += 1
      end
    end
    return num_coils
  end

  #define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Ruleset::OSArgumentVector.new
    
    #populate choice argument for air loops in the model
    air_loop_handles = OpenStudio::StringVector.new
    air_loop_display_names = OpenStudio::StringVector.new

    air_loop_display_names, air_loop_handles = airloop_chooser(model)

    #add building to string vector with air loops
    building = model.getBuilding
    air_loop_handles.unshift(building.handle.to_s)
    air_loop_display_names.unshift("*All CAV Air Loops*")

    #make an argument for air loops
    object = OpenStudio::Ruleset::OSArgument::makeChoiceArgument("object", air_loop_handles, air_loop_display_names,true)
    object.setDisplayName("Choose an Air Loop to change from CAV to VAV.")
    object.setDefaultValue("*All CAV Air Loops*") #if no air loop is chosen this will run on all air loops
    args << object

    #make an argument for cooling type
    cooling_coil_options = OpenStudio::StringVector.new
    cooling_coil_options << "Two-Stage Compressor"
    cooling_coil_options << "Four-Stage Compressor"
    cooling_coil_type = OpenStudio::Ruleset::OSArgument::makeChoiceArgument('cooling_coil_type', cooling_coil_options, true)
    cooling_coil_type.setDisplayName("Choose the type of cooling coil.")
    cooling_coil_type.setDefaultValue("Two-Stage Compressor")
    args << cooling_coil_type
    
    #make an argument for rated cooling coil EER
    rated_cc_eer = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('rated_cc_eer', false)
    rated_cc_eer.setDisplayName("Rated Cooling Coil EER")
    rated_cc_eer.setDefaultValue(15)
    args << rated_cc_eer

    #make an argument for 75% cooling coil EER
    three_quarter_cc_eer = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('three_quarter_cc_eer', false)
    three_quarter_cc_eer.setDisplayName("Cooling Coil EER at 75% Capacity")
    three_quarter_cc_eer.setDefaultValue(13)
    args << three_quarter_cc_eer

    #make an argument for 50% cooling coil EER
    half_cc_eer = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('half_cc_eer', false)
    half_cc_eer.setDisplayName("Cooling Coil EER at 50% Capacity")
    half_cc_eer.setDefaultValue(11)
    args << half_cc_eer

    #make an argument for 25% cooling coil EER
    quarter_cc_eer = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('quarter_cc_eer', false)
    quarter_cc_eer.setDisplayName("Cooling Coil EER at 25% Capacity")
    quarter_cc_eer.setDefaultValue(9)
    args << quarter_cc_eer

    #make an argument for heating type
    heating_coil_options = OpenStudio::StringVector.new
    heating_coil_options << "Gas Heating Coil"
    heating_coil_options << "Heat Pump"
    heating_coil_type = OpenStudio::Ruleset::OSArgument::makeChoiceArgument('heating_coil_type', heating_coil_options, true)
    heating_coil_type.setDisplayName("Choose the type of heating coil.")
    heating_coil_type.setDefaultValue("Gas Heating Coil")
    args << heating_coil_type

    #make an argument for rated gas heating coil efficiency
    rated_hc_gas_efficiency = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('rated_hc_gas_efficiency', false)
    rated_hc_gas_efficiency.setDisplayName("Rated Gas Heating Coil Efficiency (0-1.00)")
    rated_hc_gas_efficiency.setDefaultValue(0.80)
    args << rated_hc_gas_efficiency

    #make an argument for rated heating coil COP
    rated_hc_cop = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('rated_hc_cop', false)
    rated_hc_cop.setDisplayName("Rated Heating Coil COP")
    rated_hc_cop.setDefaultValue(3.5)
    args << rated_hc_cop

    #make an argument for 75% heating coil COP
    three_quarter_hc_cop = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('three_quarter_hc_cop', false)
    three_quarter_hc_cop.setDisplayName("Heating Coil COP at 75% Capacity")
    three_quarter_hc_cop.setDefaultValue(3.0)
    args << three_quarter_hc_cop

    #make an argument for 50% heating coil COP
    half_hc_cop = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('half_hc_cop', false)
    half_hc_cop.setDisplayName("Heating Coil COP at 50% Capacity")
    half_hc_cop.setDefaultValue(2.5)
    args << half_hc_cop

    #make an argument for 25% heating coil COP
    quarter_hc_cop = OpenStudio::Ruleset::OSArgument::makeDoubleArgument('quarter_hc_cop', false)
    quarter_hc_cop.setDisplayName("Heating Coil COP at 25% Capacity")
    quarter_hc_cop.setDefaultValue(2.0)
    args << quarter_hc_cop
    
    return args
  end #end the arguments method

  #define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)
    
    # Use the built-in error checking 
    if not runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # Assign the user inputs to variables
    object = runner.getOptionalWorkspaceObjectChoiceValue("object",user_arguments,model)
    cooling_coil_type = runner.getStringArgumentValue("cooling_coil_type",user_arguments)
    rated_cc_eer = runner.getOptionalDoubleArgumentValue("rated_cc_eer",user_arguments)
    three_quarter_cc_eer = runner.getOptionalDoubleArgumentValue("three_quarter_cc_eer",user_arguments)    
    half_cc_eer = runner.getOptionalDoubleArgumentValue("half_cc_eer",user_arguments)    
    quarter_cc_eer = runner.getOptionalDoubleArgumentValue("quarter_cc_eer",user_arguments)
    heating_coil_type = runner.getStringArgumentValue("heating_coil_type",user_arguments)
    rated_hc_gas_efficiency = runner.getOptionalDoubleArgumentValue("rated_hc_gas_efficiency",user_arguments)    
    rated_hc_cop = runner.getOptionalDoubleArgumentValue("rated_hc_cop",user_arguments)
    three_quarter_hc_cop = runner.getOptionalDoubleArgumentValue("three_quarter_hc_cop",user_arguments)
    half_hc_cop = runner.getOptionalDoubleArgumentValue("half_hc_cop",user_arguments)
    quarter_hc_cop = runner.getOptionalDoubleArgumentValue("quarter_hc_cop",user_arguments)
    
    if rated_cc_eer.empty?
      runner.registerError("User must enter a value for the rated capacity cooling coil EER.")
      return false
    elsif rated_cc_eer.to_f <= 0
      runner.registerError("Invalid rated cooling coil EER value of #{rated_cc_eer} entered. EER must be >0.")
      return false
    end

    if three_quarter_cc_eer.empty? && cooling_coil_type == "Four-Stage Compressor"
      runner.registerError("User must enter a value for 75% capacity cooling coil EER.")
      return false
    elsif three_quarter_cc_eer.to_f <= 0 && cooling_coil_type == "Four-Stage Compressor"
      runner.registerError("Invalid 75% capacity cooling coil EER value of #{three_quarter_cc_eer} entered. EER must be >0.")
      return false
    end

    if half_cc_eer.empty?
      runner.registerError("User must enter a value for 50% capacity cooling coil EER.")
      return false
    elsif half_cc_eer.to_f <= 0
      runner.registerError("Invalid 50% capacity cooling coil EER value of #{half_cc_eer} entered. EER must be >0.")
      return false
    end
 
     if quarter_cc_eer.empty? && cooling_coil_type == "Four-Stage Compressor"
      runner.registerError("User must enter a value for 25% capacity cooling coil EER.")
      return false
     elsif quarter_cc_eer.to_f <= 0 && cooling_coil_type == "Four-Stage Compressor"
       runner.registerError("Invalid 25% capacity cooling coil EER value of #{quarter_cc_eer} entered. EER must be >0.")
       return false
     end

    if rated_hc_gas_efficiency.empty? && heating_coil_type == "Gas Heating Coil"
      runner.registerError("User must enter a value for the rated gas heating coil efficiency.")
      return false
    elsif rated_hc_gas_efficiency.to_f <= 0 && heating_coil_type == "Gas Heating Coil"
      runner.registerError("Invalid rated heating coil efficiency value of #{rated_hc_gas_efficiency} entered. Value must be >0.")
      return false
    elsif rated_hc_gas_efficiency.to_f > 1 && heating_coil_type == "Gas Heating Coil"
      runner.registerError("Invalid rated heating coil efficiency value of #{rated_hc_gas_efficiency} entered. Value must be between 0 and 1.")
      return false
    end
    
    if rated_hc_cop.empty? && heating_coil_type == "Heat Pump"
      runner.registerError("User must enter a value for the rated heating coil COP.")
      return false
    elsif rated_hc_cop.to_f <= 0 && heating_coil_type == "Heat Pump"
      runner.registerError("Invalid rated heating coil COP value of #{rated_hc_cop} entered. COP must be >0.")
      return false
    end
    
    if three_quarter_hc_cop.empty? && heating_coil_type == "Heat Pump" && cooling_coil_type == "Four-Stage Compressor"
      runner.registerError("User must enter a value for 75% capacity heating coil COP.")
      return false
    elsif half_hc_cop.to_f <= 0 && heating_coil_type == "Heat Pump" && cooling_coil_type == "Four-Stage Compressor"
      runner.registerError("Invalid 75% capacity heating coil COP value of #{three_quarter_hc_cop} entered. COP must be >0.")
      return false
    end

    if half_hc_cop.empty? && heating_coil_type == "Heat Pump"
      runner.registerError("User must enter a value for 50% capacity heating coil COP.")
      return false
    elsif half_hc_cop.to_f <= 0 && heating_coil_type == "Heat Pump"
      runner.registerError("Invalid 50% capacity heating coil COP value of #{half_hc_cop} entered. COP must be >0.")
      return false
    end

    if quarter_hc_cop.empty? && heating_coil_type == "Heat Pump" && cooling_coil_type == "Four-Stage Compressor"
      runner.registerError("User must enter a value for 25% capacity heating coil COP.")
      return false
    elsif quarter_hc_cop.to_f <= 0 && heating_coil_type == "Heat Pump" && cooling_coil_type == "Four-Stage Compressor"
      runner.registerError("Invalid 25% capacity heating coil COP value of #{quarter_hc_cop} entered. COP must be >0.")
      return false
    end
    
    # Check the air loop selection
    apply_to_all_air_loops = false
    selected_airloop = nil
    if object.empty?
      handle = runner.getStringArgumentValue("object",user_arguments)
      if handle.empty?
        runner.registerError("No air loop was chosen.")
      else
        runner.registerError("The selected air loop with handle '#{handle}' was not found in the model. It may have been removed by another measure.")
      end
      return false
    else
      if not object.get.to_AirLoopHVAC.empty?
        selected_airloop = object.get.to_AirLoopHVAC.get
      elsif not object.get.to_Building.empty?
        apply_to_all_air_loops = true
      else
        runner.registerError("Script Error - argument not showing up as air loop.")
        return false
      end
    end  #end of if object.empty?
    
    # Report initial condition of model
    air_loop_handles = OpenStudio::StringVector.new
    air_loop_display_names = OpenStudio::StringVector.new
    air_loop_display_names, air_loop_handles = airloop_chooser(model)
    runner.registerInitialCondition("The building started with #{air_loop_handles.size} constant-speed RTUs.") 
    
    # Add selected airloops to an array
    selected_airloops = [] 
    if apply_to_all_air_loops == true
      #limit all airloops to only those that are appropriate
      all_airloops = []      
      all_airloops = model.getAirLoopHVACs
      all_airloops.each do |airloop|
        if air_loop_handles.include? airloop.handle.to_s
          selected_airloops << airloop
        end
      end
    else
      selected_airloops << selected_airloop
    end
    
    # Change HeatPumpAirToAir to VAV on the selected airloops, where applicable
    selected_airloops.each do |air_loop|
         
      changed_cav_to_vav = false
    
      #Make a new AirLoopHVAC:UnitarySystem object
      air_loop_hvac_unitary_system = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      air_loop_hvac_unitary_system_cooling = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      air_loop_hvac_unitary_system_heating = OpenStudio::Model::AirLoopHVACUnitarySystem.new(model)
      #initialize new setpoint managers for heating and cooling coils
      setpoint_mgr_cooling = OpenStudio::Model::SetpointManagerSingleZoneReheat.new(model)
      setpoint_mgr_heating = OpenStudio::Model::SetpointManagerSingleZoneReheat.new(model)
      setpoint_mgr_heating_sup = OpenStudio::Model::SetpointManagerSingleZoneReheat.new(model)
      #EMS initialize program
      term_zone_handle = nil
      term_zone_name = nil
      vav_fan_handle = nil
      vav_fan_act_handle = nil
      #EMS Vent program
      cc_handle = nil
      hc_handle = nil
      # add EMS sensor
      cc_name = nil
      hc_name = nil
      fan_mass_flow_rate_handle = nil
      fan_mass_flow_actuator_handle = nil
      terminal_actuator_handle = nil
      number_of_cooling_speeds = nil
      
      #TODO change to user inputs
      vent_fan_speed = 0.4
      stage_one_cooling_fan_speed = 0.4    
      stage_two_cooling_fan_speed = 0.5    
      stage_three_cooling_fan_speed = 0.75 
      stage_four_cooling_fan_speed = 1
      stage_one_heating_fan_speed = 0.4    
      stage_two_heating_fan_speed = 0.5    
      stage_three_heating_fan_speed = 0.75
      stage_four_heating_fan_speed = 1.0
    
      number_of_heat_coils = 0
      number_of_heat_coils = number_heatcoils(air_loop)
      runner.registerInfo("number of heat coils: #{number_of_heat_coils}")
          
      # Identify original AirLoopHVACUnitaryHeatPumpAirToAir
      air_loop.supplyComponents.each do |supply_comp|      
        if supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.is_initialized           
          existing_fan = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.supplyAirFan
          if existing_fan.to_FanConstantVolume.is_initialized
            existing_fan = existing_fan.to_FanConstantVolume.get
          elsif existing_fan.to_FanOnOff.is_initialized
            existing_fan = existing_fan.to_FanOnOff.get
          elsif existing_fan.to_FanVariableVolume.is_initialized
            existing_fan = existing_fan.to_FanVariableVolume.get
          end
          runner.registerInfo("existing_fan #{existing_fan.to_s}")  
          # Preserve characteristics of the original fan
          fan_pressure_rise = existing_fan.pressureRise
          fan_efficiency = existing_fan.fanEfficiency
          motor_efficiency = existing_fan.motorEfficiency
          fan_availability_schedule = existing_fan.availabilitySchedule
          
          existing_cooling_coil = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.coolingCoil
          if existing_cooling_coil.to_CoilCoolingDXSingleSpeed.is_initialized
            existing_cooling_coil = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.coolingCoil.to_CoilCoolingDXSingleSpeed.get
          elsif existing_cooling_coil.to_CoilCoolingDXTwoSpeed.is_initialized
            existing_cooling_coil = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.coolingCoil.to_CoilCoolingDXTwoSpeed.get
          end
          runner.registerInfo("existing_cooling_coil #{existing_cooling_coil.to_s}")
          
          # Add a new cooling coil object
          if cooling_coil_type == "Two-Stage Compressor"
            new_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
            cc_handle = new_cooling_coil.handle
            half_speed_cc_cop = half_cc_eer.to_f/3.412            
            new_cooling_coil_data_1 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_1.setGrossRatedCoolingCOP(half_speed_cc_cop.to_f)
            rated_speed_cc_cop = rated_cc_eer.to_f/3.412            
            new_cooling_coil_data_2 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_2.setGrossRatedCoolingCOP(rated_speed_cc_cop.to_f)
            new_cooling_coil.setFuelType("Electricity")
            new_cooling_coil.addStage(new_cooling_coil_data_1)
            new_cooling_coil.addStage(new_cooling_coil_data_2)
            air_loop_hvac_unitary_system_cooling.setCoolingCoil(new_cooling_coil) 
            # add EMS sensor
            cc_handle = new_cooling_coil.handle  
            cc_name = new_cooling_coil.name            
          elsif cooling_coil_type == "Four-Stage Compressor"
            new_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
            quarter_speed_cc_cop = quarter_cc_eer.to_f/3.412
            new_cooling_coil_data_1 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_1.setGrossRatedCoolingCOP(quarter_speed_cc_cop.to_f)
            half_speed_cc_cop = half_cc_eer.to_f/3.412
            new_cooling_coil_data_2 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_2.setGrossRatedCoolingCOP(half_speed_cc_cop.to_f)
            three_quarter_speed_cc_cop = three_quarter_cc_eer.to_f/3.412
            new_cooling_coil_data_3 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_3.setGrossRatedCoolingCOP(three_quarter_speed_cc_cop.to_f)
            rated_speed_cc_cop = rated_cc_eer.to_f/3.412
            new_cooling_coil_data_4 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_4.setGrossRatedCoolingCOP(rated_speed_cc_cop.to_f)
            new_cooling_coil.setFuelType("Electricity")
            new_cooling_coil.addStage(new_cooling_coil_data_1)
            new_cooling_coil.addStage(new_cooling_coil_data_2)
            new_cooling_coil.addStage(new_cooling_coil_data_3)
            new_cooling_coil.addStage(new_cooling_coil_data_4)
            air_loop_hvac_unitary_system_cooling.setCoolingCoil(new_cooling_coil)
            # add EMS sensor
            cc_handle = new_cooling_coil.handle  
            cc_name = new_cooling_coil.name            
          end 
          
          existing_heating_coil = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.heatingCoil
          if existing_heating_coil.to_CoilHeatingDXSingleSpeed.is_initialized
            existing_heating_coil = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.heatingCoil.to_CoilHeatingDXSingleSpeed.get
          elsif existing_heating_coil.to_CoilHeatingGas.is_initialized
            existing_heating_coil = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.heatingCoil.to_CoilHeatingGas.get
          end
          runner.registerInfo("existing_heating_coil #{existing_heating_coil.to_s}")

          # Add a new heating coil object
          if heating_coil_type == "Gas Heating Coil"
            new_heating_coil = OpenStudio::Model::CoilHeatingGas.new(model)                    
            new_heating_coil.setGasBurnerEfficiency(rated_hc_gas_efficiency.to_f)
            air_loop_hvac_unitary_system.setHeatingCoil(new_heating_coil)    
            hc_handle = new_heating_coil.handle
            hc_name = new_heating_coil.name            
          elsif heating_coil_type == "Heat Pump" && cooling_coil_type == "Two-Stage Compressor"
            new_heating_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
            new_heating_coil_data_1 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
            new_heating_coil_data_1.setGrossRatedHeatingCOP(half_hc_cop.to_f)
            new_heating_coil_data_2 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
            new_heating_coil_data_2.setGrossRatedHeatingCOP(rated_hc_cop.to_f)
            new_heating_coil.setFuelType("Electricity")
            new_heating_coil.addStage(new_heating_coil_data_1)
            new_heating_coil.addStage(new_heating_coil_data_2)
            air_loop_hvac_unitary_system.setHeatingCoil(new_heating_coil)
            hc_handle = new_heating_coil.handle
            hc_name = new_heating_coil.name
          elsif heating_coil_type == "Heat Pump" && cooling_coil_type == "Four-Stage Compressor"
            new_heating_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
            new_heating_coil_data_1 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
            new_heating_coil_data_1.setGrossRatedHeatingCOP(quarter_hc_cop.to_f)
            new_heating_coil_data_2 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
            new_heating_coil_data_2.setGrossRatedHeatingCOP(half_hc_cop.to_f)
            new_heating_coil_data_3 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
            new_heating_coil_data_3.setGrossRatedHeatingCOP(three_quarter_hc_cop.to_f)
            new_heating_coil_data_4 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
            new_heating_coil_data_4.setGrossRatedHeatingCOP(rated_hc_cop.to_f)
            new_heating_coil.setFuelType("Electricity")
            new_heating_coil.addStage(new_heating_coil_data_1)
            new_heating_coil.addStage(new_heating_coil_data_2)
            new_heating_coil.addStage(new_heating_coil_data_3)
            new_heating_coil.addStage(new_heating_coil_data_4)
            air_loop_hvac_unitary_system.setHeatingCoil(new_heating_coil)
            hc_handle = new_heating_coil.handle
            hc_name = new_heating_coil.name
          end   
          
          supplementalHeat = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.supplementalHeatingCoil
          if supplementalHeat.to_CoilHeatingElectric.is_initialized
            number_of_heat_coils = 2
            runner.registerInfo("setting number of heat coils to 2:")
            supplementalHeat = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.supplementalHeatingCoil.to_CoilHeatingElectric.get
            air_loop_hvac_unitary_system_heating.setHeatingCoil(supplementalHeat)
            runner.registerInfo("supplementalHeat #{air_loop_hvac_unitary_system_heating.heatingCoil.get.to_s}")
            #set heatpump supplemental to a temp coil
            temp = OpenStudio::Model::CoilHeatingGas.new(model)
            supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.setSupplementalHeatingCoil(temp)
          elsif supplementalHeat.to_CoilHeatingGas.is_initialized
            number_of_heat_coils = 2
            runner.registerInfo("setting number of heat coils to 2:")
            supplementalHeat = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.supplementalHeatingCoil.to_CoilHeatingGas.get
            air_loop_hvac_unitary_system_heating.setHeatingCoil(supplementalHeat)
            runner.registerInfo("supplementalHeat #{air_loop_hvac_unitary_system_heating.heatingCoil.get.to_s}")
            #set heatpump supplemental to a temp coil
            temp = OpenStudio::Model::CoilHeatingGas.new(model)
            supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.setSupplementalHeatingCoil(temp)
          end
          runner.registerInfo("supplementalHeat #{supplementalHeat.to_s}")
          
          # Get the previous and next components on the loop     
          prev_node = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.inletModelObject.get.to_Node.get        
          next_node = supply_comp.to_AirLoopHVACUnitaryHeatPumpAirToAir.get.outletModelObject.get.to_Node.get
          runner.registerInfo("prev_node #{prev_node.to_s}")
          # Make the new vav_fan and transfer existing parameters to it
          vav_fan = OpenStudio::Model::FanVariableVolume.new(model, model.alwaysOnDiscreteSchedule)
          vav_fan.setPressureRise(fan_pressure_rise)
          vav_fan.setFanEfficiency(fan_efficiency)
          vav_fan.setMotorEfficiency(motor_efficiency)
          vav_fan.setAvailabilitySchedule(fan_availability_schedule)
          
          ems_fan_internal = OpenStudio::Model::EnergyManagementSystemInternalVariable.new(model, "Fan Maximum Mass Flow Rate")
          ems_fan_internal.setName("#{vav_fan.name}_mass_flow_rate")
          ems_fan_internal.setInternalDataIndexKeyName("#{vav_fan.name}")
          fan_mass_flow_rate_handle = ems_fan_internal.handle
          
          fan_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(vav_fan,"Fan","Fan Air Mass Flow Rate") 
          fan_actuator.setName("#{vav_fan.name}_mass_flow_actuator") 
          fan_mass_flow_actuator_handle = fan_actuator.handle
          #Add Fan to EMS init program
      	  vav_fan_handle = vav_fan.handle
          vav_fan_act_handle = fan_actuator.handle
      	
          # Remove the supply fan
          existing_fan.remove
          # Remove the existing cooling coil.
          existing_cooling_coil.remove                    
          # Remove the existing heating coil.
          existing_heating_coil.remove
          # Remove the existing heatpump
          supply_comp.remove
          
          # Get back the remaining node
          remaining_node = nil
          if prev_node.outletModelObject.is_initialized
            remaining_node = prev_node
          elsif next_node.inletModelObject.is_initialized
            remaining_node = next_node
          end
             
          # Add a new AirLoopHVAC:UnitarySystem object to the node where the old fan was
          if remaining_node.nil?
            runner.registerError("Couldn't add the new AirLoopHVAC:UnitarySystem object to the loop after removing existing CAV fan.")
            return false
          else
            air_loop_hvac_unitary_system.addToNode(remaining_node)
            air_loop_hvac_unitary_system_heating.addToNode(remaining_node) 
            air_loop_hvac_unitary_system_cooling.addToNode(remaining_node)                        
          end
          
          # Change the unitary system control type to setpoint to enable the VAV fan to ramp down.
          air_loop_hvac_unitary_system.setString(2,"Setpoint")
          air_loop_hvac_unitary_system_cooling.setString(2,"Setpoint") 
          air_loop_hvac_unitary_system_heating.setString(2,"Setpoint")
          # Add the VAV fan to the AirLoopHVAC:UnitarySystem object
          air_loop_hvac_unitary_system.setSupplyFan(vav_fan)
          
          # Set the AirLoopHVAC:UnitarySystem fan placement
          air_loop_hvac_unitary_system.setFanPlacement("BlowThrough")
          
          # Set the AirLoopHVAC:UnitarySystem Supply Air Fan Operating Mode Schedule
          air_loop_hvac_unitary_system.setSupplyAirFanOperatingModeSchedule(model.alwaysOnDiscreteSchedule)

          #let the user know that a change was made
          changed_cav_to_vav = true
          runner.registerInfo("AirLoop '#{air_loop.name}' was changed to VAV")
          
        end  #end orig fan
      end #next supply component
      
      # Find CAV/OnOff fan and replace with VAV fan
      air_loop.supplyComponents.each do |supply_comp|       
        # Identify original fan from loop
        found_fan = false
        if supply_comp.to_FanConstantVolume.is_initialized
          existing_fan = supply_comp.to_FanConstantVolume.get
          found_fan = true
        elsif supply_comp.to_FanOnOff.is_initialized  
          existing_fan = supply_comp.to_FanOnOff.get
          found_fan = true
        end    
        if found_fan == true        
          # Preserve characteristics of the original fan
          fan_pressure_rise = existing_fan.pressureRise
          fan_efficiency = existing_fan.fanEfficiency
          motor_efficiency = existing_fan.motorEfficiency
          fan_availability_schedule = existing_fan.availabilitySchedule
          
          # Get the previous and next components on the loop     
          prev_node = existing_fan.inletModelObject.get.to_Node.get        
          next_node = existing_fan.outletModelObject.get.to_Node.get
         
          # Make the new vav_fan and transfer existing parameters to it
          vav_fan = OpenStudio::Model::FanVariableVolume.new(model, model.alwaysOnDiscreteSchedule)
          vav_fan.setPressureRise(fan_pressure_rise)
          vav_fan.setFanEfficiency(fan_efficiency)
          vav_fan.setMotorEfficiency(motor_efficiency)
          vav_fan.setAvailabilitySchedule(fan_availability_schedule)
          
          ems_fan_internal = OpenStudio::Model::EnergyManagementSystemInternalVariable.new(model, "Fan Maximum Mass Flow Rate")
          ems_fan_internal.setName("#{vav_fan.name}_mass_flow_rate")
          ems_fan_internal.setInternalDataIndexKeyName("#{vav_fan.name}")
          fan_mass_flow_rate_handle = ems_fan_internal.handle
          
          fan_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(vav_fan,"Fan","Fan Air Mass Flow Rate") 
          fan_actuator.setName("#{vav_fan.name}_mass_flow_actuator") 
          fan_mass_flow_actuator_handle = fan_actuator.handle
          #Add Fan to EMS init program 
      	  vav_fan_handle = vav_fan.handle
          vav_fan_act_handle = fan_actuator.handle
          
          # Remove the supply fan
          existing_fan.remove
          
          # Get back the remaining node
          remaining_node = nil
          if prev_node.outletModelObject.is_initialized
            remaining_node = prev_node
          elsif next_node.inletModelObject.is_initialized
            remaining_node = next_node
          end
             
          # Add a new AirLoopHVAC:UnitarySystem object to the node where the old fan was
          if remaining_node.nil?
            runner.registerError("Couldn't add the new AirLoopHVAC:UnitarySystem object to the loop after removing existing CAV fan.")
            return false
          else
            air_loop_hvac_unitary_system.addToNode(remaining_node)
            air_loop_hvac_unitary_system_heating.addToNode(remaining_node)
            air_loop_hvac_unitary_system_cooling.addToNode(remaining_node)            
          end
          
          # Change the unitary system control type to setpoint to enable the VAV fan to ramp down.
          air_loop_hvac_unitary_system.setString(2,"Setpoint")
          air_loop_hvac_unitary_system_cooling.setString(2,"Setpoint") 
          air_loop_hvac_unitary_system_heating.setString(2,"Setpoint")
          # Add the VAV fan to the AirLoopHVAC:UnitarySystem object
          air_loop_hvac_unitary_system.setSupplyFan(vav_fan)
          
          # Set the AirLoopHVAC:UnitarySystem fan placement
          air_loop_hvac_unitary_system.setFanPlacement("BlowThrough")
          
          # Set the AirLoopHVAC:UnitarySystem Supply Air Fan Operating Mode Schedule
          air_loop_hvac_unitary_system.setSupplyAirFanOperatingModeSchedule(model.alwaysOnDiscreteSchedule)

          #let the user know that a change was made
          changed_cav_to_vav = true
          runner.registerInfo("AirLoop '#{air_loop.name}' was changed to VAV")
          
        end  #end orig fan

      
      # Move the cooling coil to the AirLoopHVAC:UnitarySystem object
        if supply_comp.to_CoilCoolingDXTwoSpeed.is_initialized || supply_comp.to_CoilCoolingDXSingleSpeed.is_initialized
          #if supply_comp.to_CoilCoolingDXTwoSpeed.is_initialized
          #  existing_cooling_coil = supply_comp.to_CoilCoolingDXTwoSpeed.get
          #elsif supply_comp.to_CoilCoolingDXSingleSpeed.is_initialized
          #  existing_cooling_coil = supply_comp.to_CoilCoolingDXSingleSpeed.get
          #end
          existing_cooling_coil = supply_comp
          # Remove the existing heating coil.
          #existing_cooling_coil.remove
          
          # Add a new cooling coil object
          if cooling_coil_type == "Two-Stage Compressor"
            new_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
            half_speed_cc_cop = half_cc_eer.to_f/3.412            
            new_cooling_coil_data_1 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_1.setGrossRatedCoolingCOP(half_speed_cc_cop.to_f)
            rated_speed_cc_cop = rated_cc_eer.to_f/3.412            
            new_cooling_coil_data_2 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_2.setGrossRatedCoolingCOP(rated_speed_cc_cop.to_f)
            new_cooling_coil.setFuelType("Electricity")
            new_cooling_coil.addStage(new_cooling_coil_data_1)
            new_cooling_coil.addStage(new_cooling_coil_data_2)
            air_loop_hvac_unitary_system_cooling.setCoolingCoil(new_cooling_coil) 
            # add EMS sensor
            cc_handle = new_cooling_coil.handle  
            cc_name = new_cooling_coil.name            
          elsif cooling_coil_type == "Four-Stage Compressor"
            new_cooling_coil = OpenStudio::Model::CoilCoolingDXMultiSpeed.new(model)
            quarter_speed_cc_cop = quarter_cc_eer.to_f/3.412
            new_cooling_coil_data_1 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_1.setGrossRatedCoolingCOP(quarter_speed_cc_cop.to_f)
            half_speed_cc_cop = half_cc_eer.to_f/3.412
            new_cooling_coil_data_2 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_2.setGrossRatedCoolingCOP(half_speed_cc_cop.to_f)
            three_quarter_speed_cc_cop = three_quarter_cc_eer.to_f/3.412
            new_cooling_coil_data_3 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_3.setGrossRatedCoolingCOP(three_quarter_speed_cc_cop.to_f)
            rated_speed_cc_cop = rated_cc_eer.to_f/3.412
            new_cooling_coil_data_4 = OpenStudio::Model::CoilCoolingDXMultiSpeedStageData.new(model)
            new_cooling_coil_data_4.setGrossRatedCoolingCOP(rated_speed_cc_cop.to_f)
            new_cooling_coil.setFuelType("Electricity")
            new_cooling_coil.addStage(new_cooling_coil_data_1)
            new_cooling_coil.addStage(new_cooling_coil_data_2)
            new_cooling_coil.addStage(new_cooling_coil_data_3)
            new_cooling_coil.addStage(new_cooling_coil_data_4)
            air_loop_hvac_unitary_system_cooling.setCoolingCoil(new_cooling_coil)
            # add EMS sensor
            cc_handle = new_cooling_coil.handle 
            cc_name = new_cooling_coil.name            
          end          
        end  #end cooling coil
      
        #only look for electric heat if there are more than 1 heat coils
        if number_of_heat_coils == 2
          if supply_comp.to_CoilHeatingElectric.is_initialized
            #its a supplemental coil
            supplementalHeat = supply_comp.to_CoilHeatingElectric.get
            air_loop_hvac_unitary_system_heating.setHeatingCoil(supplementalHeat)
          end
        end
      # Move the heating coil to the AirLoopHVAC:UnitarySystem object
        if supply_comp.to_CoilHeatingGas.is_initialized || supply_comp.to_CoilHeatingDXSingleSpeed.is_initialized
          #check if heating coil is supplemental
          is_supp = 0
          if supply_comp.to_CoilHeatingGas.is_initialized
            if number_of_heat_coils == 2
              if supply_comp.to_CoilHeatingGas.get.name.to_s.include? "Backup"
                is_supp = 1
              end              
            end
          end
          if is_supp == 1
            #its a supplemental coil
            supplementalHeat = supply_comp.to_CoilHeatingGas.get
            air_loop_hvac_unitary_system_heating.setHeatingCoil(supplementalHeat)
          else
            # Add a new heating coil object
            if heating_coil_type == "Gas Heating Coil"
              new_heating_coil = OpenStudio::Model::CoilHeatingGas.new(model)      
              hc_handle = new_heating_coil.handle 
              hc_name = new_heating_coil.name            
              new_heating_coil.setGasBurnerEfficiency(rated_hc_gas_efficiency.to_f)
              air_loop_hvac_unitary_system.setHeatingCoil(new_heating_coil)               
            elsif heating_coil_type == "Heat Pump" && cooling_coil_type == "Two-Stage Compressor"
              new_heating_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
              hc_handle = new_heating_coil.handle
              hc_name = new_heating_coil.name
              new_heating_coil_data_1 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
              new_heating_coil_data_1.setGrossRatedHeatingCOP(half_hc_cop.to_f)
              new_heating_coil_data_2 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
              new_heating_coil_data_2.setGrossRatedHeatingCOP(rated_hc_cop.to_f)
              new_heating_coil.setFuelType("Electricity")
              new_heating_coil.addStage(new_heating_coil_data_1)
              new_heating_coil.addStage(new_heating_coil_data_2)
              air_loop_hvac_unitary_system.setHeatingCoil(new_heating_coil)
            elsif heating_coil_type == "Heat Pump" && cooling_coil_type == "Four-Stage Compressor"
              new_heating_coil = OpenStudio::Model::CoilHeatingDXMultiSpeed.new(model)
              hc_handle = new_heating_coil.handle
              hc_name = new_heating_coil.name
              new_heating_coil_data_1 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
              new_heating_coil_data_1.setGrossRatedHeatingCOP(quarter_hc_cop.to_f)
              new_heating_coil_data_2 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
              new_heating_coil_data_2.setGrossRatedHeatingCOP(half_hc_cop.to_f)
              new_heating_coil_data_3 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
              new_heating_coil_data_3.setGrossRatedHeatingCOP(three_quarter_hc_cop.to_f)
              new_heating_coil_data_4 = OpenStudio::Model::CoilHeatingDXMultiSpeedStageData.new(model)
              new_heating_coil_data_4.setGrossRatedHeatingCOP(rated_hc_cop.to_f)
              new_heating_coil.setFuelType("Electricity")
              new_heating_coil.addStage(new_heating_coil_data_1)
              new_heating_coil.addStage(new_heating_coil_data_2)
              new_heating_coil.addStage(new_heating_coil_data_3)
              new_heating_coil.addStage(new_heating_coil_data_4)
              air_loop_hvac_unitary_system.setHeatingCoil(new_heating_coil)
            end    
          end  #is_supp
        end  #end heating coil
         
      end #next supply component
      #remove supplemental unitary system if not needed
      if number_of_heat_coils < 2
        air_loop_hvac_unitary_system_heating.remove
      end
      #OA node deletion fix
      air_loop.supplyComponents.each do |supply_comp|
        if supply_comp.to_CoilCoolingDXTwoSpeed.is_initialized || supply_comp.to_CoilCoolingDXSingleSpeed.is_initialized
          existing_cooling_coil = supply_comp
          # Remove the existing cooling coil.
          existing_cooling_coil.remove        
        end
        if supply_comp.to_CoilHeatingGas.is_initialized || supply_comp.to_CoilHeatingDXSingleSpeed.is_initialized || supply_comp.to_CoilHeatingElectric.is_initialized
          existing_heating_coil = supply_comp
          # Remove the existing heating coil.
          existing_heating_coil.remove        
        end
      end

      # Find the supply outlet node for the current AirLoop
      airloop_outlet_node = air_loop.supplyOutletNode
      
      # Identify if there is a setpoint manager on the AirLoop outlet node
      if airloop_outlet_node.setpointManagers.size >0
        setpoint_manager = airloop_outlet_node.setpointManagers[0]
        setpoint_manager = setpoint_manager.to_SetpointManagerSingleZoneReheat.get
        runner.registerInfo("Setpoint manager on node '#{airloop_outlet_node.name}' is '#{setpoint_manager.name}'.")        
        setpoint_mgr_cooling.setMaximumSupplyAirTemperature(setpoint_manager.maximumSupplyAirTemperature)
        setpoint_mgr_cooling.setMinimumSupplyAirTemperature(setpoint_manager.minimumSupplyAirTemperature)
        setpoint_mgr_heating.setMaximumSupplyAirTemperature(setpoint_manager.maximumSupplyAirTemperature)
        setpoint_mgr_heating.setMinimumSupplyAirTemperature(setpoint_manager.minimumSupplyAirTemperature)
        setpoint_manager.remove
      else
        runner.registerInfo("No setpoint manager on node '#{airloop_outlet_node.name}'.")
      end
      #attach setpoint managers now that everything else is deleted
      setpoint_mgr_heating.addToNode(air_loop_hvac_unitary_system.airOutletModelObject.get.to_Node.get)
      if number_of_heat_coils == 2
        setpoint_mgr_heating_sup.addToNode(air_loop_hvac_unitary_system_heating.airOutletModelObject.get.to_Node.get)
      end
      setpoint_mgr_cooling.addToNode(air_loop_hvac_unitary_system_cooling.airOutletModelObject.get.to_Node.get)
      
      # Set the controlling zone location to the zone on the airloop
      air_loop.demandComponents.each do |demand_comp|
        if demand_comp.to_AirTerminalSingleDuctUncontrolled.is_initialized 
	
    	  terminal_obj = demand_comp.to_AirTerminalSingleDuctUncontrolled.get
        #add EMS Actuator
    	  terminal_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(terminal_obj,"AirTerminal:SingleDuct:Uncontrolled","Mass Flow Rate") 
        terminal_actuator.setName("#{terminal_obj.name.to_s.gsub('-','_')}_mass_flow_actuator")    
        terminal_actuator_handle = terminal_actuator.handle   
          # Record the zone that the terminal unit is in.
          # If zone cannot be determined, skip to next demand component
          # and warn user that this the associated zone could not be found
          term_zone = nil
          model.getThermalZones.each do |zone|
            zone.equipment.each do |equip|
              if equip == terminal_obj
                term_zone = zone
              end
            end
          end
          if term_zone.nil?
            runner.registerWarning("Could not determine the zone for terminal '#{new_vav_terminal.name}', cannot assign to AirLoopHVAC:UnitarySystem object.")
            next
          else
            # Associate the zone with the AirLoopHVAC:UnitarySystem object and setpoint managers
            air_loop_hvac_unitary_system.setControllingZoneorThermostatLocation(term_zone)
            air_loop_hvac_unitary_system_cooling.setControllingZoneorThermostatLocation(term_zone)
            setpoint_mgr_cooling.setControlZone(term_zone)
            setpoint_mgr_heating.setControlZone(term_zone)
            setpoint_mgr_heating_sup.setControlZone(term_zone)
            #Add Zone to EMS init program
            term_zone_handle = term_zone.handle
            term_zone_name = term_zone.name
          end
        end  
      end
      
      # add EMS sensor
      cc_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Cooling Coil Total Cooling Rate")
      cc_sensor.setKeyName(cc_handle.to_s)
      cc_sensor.setName("#{cc_name}_cooling_rate")   

      hc_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Heating Coil Air Heating Rate")
      hc_sensor.setKeyName(hc_handle.to_s)
      hc_sensor.setName("#{hc_name}_heating_rate")      
          
      ems_design_heat_internal = OpenStudio::Model::EnergyManagementSystemInternalVariable.new(model, "Unitary HVAC Design Heating Capacity")
      ems_design_heat_internal.setName("#{air_loop_hvac_unitary_system.name}_heating_cap")
      ems_design_heat_internal.setInternalDataIndexKeyName("#{air_loop_hvac_unitary_system.name}")
      
      ems_design_cool_internal = OpenStudio::Model::EnergyManagementSystemInternalVariable.new(model, "Unitary HVAC Design Cooling Capacity")
      ems_design_cool_internal.setName("#{air_loop_hvac_unitary_system.name}_cooling_cap")
      ems_design_cool_internal.setInternalDataIndexKeyName("#{air_loop_hvac_unitary_system.name}")
      
      zone_init_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      zone_init_program.setName("#{term_zone_name}_Initialization_Prgm")
      zone_init_program.addLine("SET #{fan_mass_flow_actuator_handle} = null")
      zone_init_program.addLine("SET #{terminal_actuator_handle} = null")
      
      vent_control_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      vent_control_program.setName("#{term_zone_name}_Vent_Ctrl_Prgm") 
      vent_control_program.addLine("SET Current_Cooling_Capacity = #{cc_sensor.handle}")
      vent_control_program.addLine("SET Current_Heating_Capacity = #{hc_sensor.handle}")
      vent_control_program.addLine("SET Design_Fan_Mass_Flow = #{fan_mass_flow_rate_handle}")
      vent_control_program.addLine("IF (Current_Cooling_Capacity == 0 && Current_Heating_Capacity == 0)")
      vent_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{vent_fan_speed} * Design_Fan_Mass_Flow)")
      vent_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow")
      vent_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
      vent_control_program.addLine("ENDIF")
      
      cc_control_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      if cooling_coil_type == "Two-Stage Compressor"
        cc_control_program.setName("#{term_zone_name}_CC_Ctrl_Prgm")   
        cc_control_program.addLine("SET Design_CC_Capacity = #{ems_design_cool_internal.handle}")
        cc_control_program.addLine("SET Current_Cooling_Capacity = #{cc_sensor.handle}")
        cc_control_program.addLine("SET Design_Fan_Mass_Flow = #{fan_mass_flow_rate_handle}")
        cc_control_program.addLine("IF (Current_Cooling_Capacity > 0 && Current_Cooling_Capacity <= (0.5 * Design_CC_Capacity))")
        cc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_one_cooling_fan_speed} * Design_Fan_Mass_Flow)")
        cc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
        cc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
        cc_control_program.addLine("ELSEIF Current_Cooling_Capacity > (0.5 * Design_CC_Capacity)")
        cc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_two_cooling_fan_speed} * Design_Fan_Mass_Flow)")
        cc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
        cc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
        cc_control_program.addLine("ENDIF")          
      elsif cooling_coil_type == "Four-Stage Compressor"       
        cc_control_program.setName("#{term_zone_name}_CC_Ctrl_Prgm")   
        cc_control_program.addLine("SET Design_CC_Capacity = #{ems_design_cool_internal.handle}")
        cc_control_program.addLine("SET Current_Cooling_Capacity = #{cc_sensor.handle}")
        cc_control_program.addLine("SET Design_Fan_Mass_Flow = #{fan_mass_flow_rate_handle}")
        cc_control_program.addLine("IF (Current_Cooling_Capacity > 0 && Current_Cooling_Capacity <= (0.25 * Design_CC_Capacity))")
        cc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_one_cooling_fan_speed} * Design_Fan_Mass_Flow)")
        cc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
        cc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
        cc_control_program.addLine("ELSEIF (Current_Cooling_Capacity > (0.25 * Design_CC_Capacity) && Current_Cooling_Capacity <= (0.50 * Design_CC_Capacity))")
        cc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_two_cooling_fan_speed} * Design_Fan_Mass_Flow)")
        cc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
        cc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
        cc_control_program.addLine("ELSEIF (Current_Cooling_Capacity > (0.50 * Design_CC_Capacity) && Current_Cooling_Capacity <= (0.75 * Design_CC_Capacity))")
        cc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_three_cooling_fan_speed} * Design_Fan_Mass_Flow)")
        cc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
        cc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
        cc_control_program.addLine("ELSEIF Current_Cooling_Capacity > (0.75 * Design_CC_Capacity)")
        cc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_four_cooling_fan_speed} * Design_Fan_Mass_Flow)")
        cc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
        cc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
        cc_control_program.addLine("ENDIF")        
      end
      
      hc_control_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
      if heating_coil_type == "Gas Heating Coil"
        hc_control_program.setName("#{term_zone_name}_HC_Ctrl_Prgm")
        hc_control_program.addLine("SET Current_Heating_Capacity = #{hc_sensor.handle}")
        hc_control_program.addLine("SET Design_Fan_Mass_Flow = #{fan_mass_flow_rate_handle}")
        hc_control_program.addLine("IF Current_Heating_Capacity > 0")
        hc_control_program.addLine("SET Timestep_Fan_Mass_Flow = Design_Fan_Mass_Flow")
        hc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
        hc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
        hc_control_program.addLine("ENDIF")	    
      elsif heating_coil_type == "Heat Pump"
        if cooling_coil_type == "Two-Stage Compressor"
          hc_control_program.setName("#{term_zone_name}_HC_Ctrl_Prgm")   
          hc_control_program.addLine("SET Design_HC_Capacity = #{ems_design_cool_internal.handle}")
          hc_control_program.addLine("SET Current_Heating_Capacity = #{hc_sensor.handle}")
          hc_control_program.addLine("SET Design_Fan_Mass_Flow = #{fan_mass_flow_rate_handle}")
          hc_control_program.addLine("IF (Current_Heating_Capacity > 0 && Current_Heating_Capacity <= (0.50 * Design_HC_Capacity))")
          hc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_one_heating_fan_speed} * Design_Fan_Mass_Flow)")
          hc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
          hc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
          hc_control_program.addLine("ELSEIF Current_Heating_Capacity > (0.50 * Design_HC_Capacity)")
          hc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_two_heating_fan_speed} * Design_Fan_Mass_Flow)")
          hc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
          hc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
          hc_control_program.addLine("ENDIF")    
        elsif cooling_coil_type == "Four-Stage Compressor"
          hc_control_program.setName("#{term_zone_name}_HC_Ctrl_Prgm") 
          hc_control_program.addLine("SET Design_HC_Capacity = #{ems_design_cool_internal.handle}")
          hc_control_program.addLine("SET Current_Heating_Capacity = #{hc_sensor.handle}")
          hc_control_program.addLine("SET Design_Fan_Mass_Flow = #{fan_mass_flow_rate_handle}")
          hc_control_program.addLine("IF (Current_Heating_Capacity > 0 && Current_Heating_Capacity <= (0.25 * Design_HC_Capacity))")
          hc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_one_heating_fan_speed} * Design_Fan_Mass_Flow)")
          hc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
          hc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
          hc_control_program.addLine("ELSEIF (Current_Heating_Capacity > (0.25 * Design_HC_Capacity) && Current_Heating_Capacity <= (0.50 * Design_HC_Capacity))")
          hc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_two_heating_fan_speed} * Design_Fan_Mass_Flow)")
          hc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
          hc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
          hc_control_program.addLine("ELSEIF (Current_Heating_Capacity > (0.50 * Design_HC_Capacity) && Current_Heating_Capacity <= (0.75 * Design_HC_Capacity))")
          hc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_three_heating_fan_speed} * Design_Fan_Mass_Flow)")
          hc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
          hc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
          hc_control_program.addLine("ELSEIF Current_Heating_Capacity > (0.75 * Design_HC_Capacity)")
          hc_control_program.addLine("SET Timestep_Fan_Mass_Flow = (#{stage_four_heating_fan_speed} * Design_Fan_Mass_Flow)")
          hc_control_program.addLine("SET #{terminal_actuator_handle} = Timestep_Fan_Mass_Flow")
          hc_control_program.addLine("SET #{fan_mass_flow_actuator_handle} = Timestep_Fan_Mass_Flow, !- Added for test of two actuator code")
          hc_control_program.addLine("ENDIF")         
        end
      end
      
      pcm = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
      pcm.setName("#{term_zone_name} Control Program")
      pcm.setCallingPoint("AfterPredictorBeforeHVACManagers")
      pcm.addProgram(zone_init_program)
      pcm.addProgram(vent_control_program)
      pcm.addProgram(cc_control_program)
      pcm.addProgram(hc_control_program)

    end # Next selected airloop

    # Report final condition of model
    final_air_loop_handles = OpenStudio::StringVector.new
    final_air_loop_display_names = OpenStudio::StringVector.new
    final_air_loop_display_names, final_air_loop_handles = airloop_chooser(model)
    runner.registerFinalCondition("The building finished with #{final_air_loop_handles.size} constant-speed RTUs.") 
    
    if final_air_loop_handles.size == air_loop_handles.size
      runner.registerAsNotApplicable("This measure is not applicable; no variable speed RTUs were added.")
    end
   
    return true
 
  end #end the run method

end #end the measure

# register the measure to be used by the application
CreateVariableSpeedRTU.new.registerWithApplication
