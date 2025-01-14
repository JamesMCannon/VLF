module VLF

    #Import needed modules
    using MAT
    using Dates
    using Plots
    using Parameters

    #Export all function names; can use VLF.foo() for any function, exported or not
    export read_multiple_mat_files
    export read_data
    export start_time
    export merge_data
    export label_maker
    export plot_data
    export unwrap
    export calibrate_NB
    export combine_2ch
    export plot_day
    export plot_multi_site
    export tx_On
    export stitchPhase

    struct fileData
        date::Date
        time::Vector{Float64} #Seconds from start of day
        data::Vector{Float64} #amplitude or phase
        Fc::Float64 #center frequency of file, Hz
        Fs::Float64 #Sample frequency of file, Hz
        adc_channel_number::Int64 #0 => NS, 1=> EW, -1=> Combined Channels
    end

    function read_multiple_mat_files(folder_path::AbstractString, include_pattern::AbstractString)
        mat_files = filter(f -> isfile(joinpath(folder_path, f)), readdir(folder_path))
        data = []
    
        for file in mat_files
            if occursin(".mat", file)
                file_path = joinpath(folder_path, file)
                
                # Check if the file should be included based on the common part of the file name
                include_file = occursin(include_pattern, file)
                
                if include_file
                    mat_contents = matopen(file_path)
                    push!(data, mat_contents)
                end
                try
                    close(file_path) 
                catch
                end
            end
        end
    
        return data
    end

    function read_multiple_mat_files(folder_path::AbstractString, include_pattern::Regex)
        mat_files = filter(f -> isfile(joinpath(folder_path, f)), readdir(folder_path))
        data = []
    
        for file in mat_files
            if occursin(".mat", file)
                file_path = joinpath(folder_path, file)
                
                # Check if the file should be included based on the common part of the file name
                include_file = occursin(include_pattern, file)
                
                if include_file
                    mat_contents = matopen(file_path)
                    push!(data, mat_contents)
                end
                try
                    close(file_path) 
                catch
                end
            end
        end
    
        return data
    end

    function read_data(files::Vector,first_date::String="2000-01-01",last_date::String="2500-01-01") 
        #=
            files: Vector{Any} containing MAT.MAT_v4.Matlabv4File s of data. Usually, 1 transmitter, 1 channel, amplitude OR phase at a time
            first_date: Start date (inclusive) of desired output data set
            last_date: End date (inclusive) of desired output data set

            output: vector of fileData structures organized by date containing the requested data
            
            read_data pulls data from mat files contained in files and pushes to output as a vector of fileData. 

            TODO could be more robust in checking Fc, amp vs phase, adc_channel_number, etc when determining when to add to prior struct vs creating a new struct

            TODO more robust logic for the case that files are opened un-ordered (i.e., files 3 and 5 share a date but file 4 has a different date)

            TODO check time vector math for 50Hz... might currently be 1/50Hz

            authors: James M Cannon
            date of last modification: 04/24/24
        =#
        #Get all information needed form each data file, push into array of arrays
        output = Vector{fileData}()

        for i in eachindex(files)
            try 
                cur_year = read(files[i],"start_year")[1]
                cur_month = read(files[i],"start_month")[1]
                cur_day =  read(files[i],"start_day")[1]

                cur_date = Date(cur_year,cur_month,cur_day)
            
                if Dates.value(cur_date) >= Dates.value(Date(first_date)) && Dates.value(cur_date) <= Dates.value(Date(last_date))

                    #Need the [1] behind each "read" function because "read" returns a matrix
                    cur_min = read(files[i],"start_minute")[1]
                    cur_hour = read(files[i],"start_hour")[1]
                    cur_sec = read(files[i],"start_second")[1]
                    cur_Fs = read(files[i],"Fs")[1]
                    cur_Fc = read(files[i],"Fc")[1]
                    cur_adc = read(files[i],"adc_channel_number")[1]

                    cur_data =  vec(read(files[i],"data"))

                    cur_secs = cur_Fs*(cur_sec + cur_min*60 + cur_hour*3600)
                    secs_vec = cur_secs:cur_Fs:cur_secs+length(cur_data)-1

                    if length(output)>0#this section combines files of the same day
                        if output[end].date == cur_date #If this file contains data for the same day as the previous file, append the data to the most recent data structure in the output vector
                            append!(output[end].time,secs_vec)
                            append!(output[end].data,cur_data)
                        else #Otherwise create a new data structure and append it to the output vector
                            cur_strut = fileData(cur_date,secs_vec,cur_data,cur_Fc,cur_Fs,cur_adc)
                            push!(output, cur_strut)
                        end
                    else #if this is the first opened file, create the first data structure and append to the output vector
                        cur_strut = fileData(cur_date,secs_vec,cur_data,cur_Fc,cur_Fs,cur_adc)
                        push!(output, cur_strut)
                    end
                    
                    prior_date = cur_date

                end
            catch x
                println("Unable to read file: ",files[i])
                println(x,"\n\n") #print the exception that caused the file to be unreadable for better debugging ability
            end
            try
                close(files[i]) 
            catch
            end
        end
        return output
	end


    function calibrate_NB(raw_data::Vector{fileData};cal_file::String="default",cal_num::Float64=-1.0)
        #=  
            raw_data: Narrowband data returned by the read_data() fcn. Expected to be a vector of fileData structures 
            cal_file: the path to the relevant calibration file for the receiver whose data is contained in raw_data - if applicable
            cal_num: The cal_num coefficient for the receiver channel corresponding to the data in raw_data - if applicable

            calibrate_NB calibrates the Narrowband data contained in raw_data using the frequency response contained in cal_file or specified in cal_num

            authors: James M Cannon
            date of last modification: 04/25/24
        =#
        cal_structure = Vector{fileData}(undef,length(raw_data))
        for i in eachindex(raw_data)
            cal_structure[i] = calibrate_NB(raw_data[i],cal_file=cal_file,cal_num=cal_num)
        end
        return cal_structure
    end



    function calibrate_NB(raw_data::fileData; cal_file::String="default",cal_num::Float64=-1.0)
        #=  
            raw_data: Narrowband data returned by the read_data() fcn. Expected to be a single fileData structure 
            cal_file: the path to the relevant calibration file for the receiver whose data is contained in raw_data - if applicable
            cal_num: The cal_num coefficient for the receiver channel corresponding to the data in raw_data - if applicable

            calibrate_NB calibrates the Narrowband data contained in raw_data using the frequency response contained in cal_file or specified in cal_num

            authors: James M Cannon
            date of last modification: 04/25/24
        =#

        if cal_file=="default" && cal_num!=-1.0
            #use cal_num
            cal_factor = cal_num
        elseif cal_num==-1.0 && cal_file!="default"
            mat_contents = matopen(cal_file)

            if raw_data.adc_channel_number == 0 #0 => NS, 1=> EW
                cal_curve = read(mat_contents,"CalibrationNumberNS")
            elseif raw_data.adc_channel_number == 1
                 cal_curve = read(mat_contents,"CalibrationNumberEW")
            else
                error("Unexpected Channel Number: ", raw_data.adc_channel_number)
            end
    
            freqs = abs.(cal_curve[:,1])
            response = abs.(cal_curve[:,2])
    
            Fc_idx = findmin(abs.(freqs.*1000 .-raw_data.Fc))[2] #find the index of the entry closest to the transmitter frequency used in the data
    
            cal_factor = response[Fc_idx]
            #CalibrationNumber, contained in response[], is a coefficient to convert from DAQ counts to pT
            close(mat_contents)
        else
            error("Calibration information not provided")
        end 

        cal_structure = fileData(raw_data.date,raw_data.time,raw_data.data .* cal_factor,raw_data.Fc,raw_data.Fs,raw_data.adc_channel_number)
        
        try
            close(cal_file) 
        catch
        end
        return cal_structure
    
    end

    function combine_2ch(cal_data1::Tuple, cal_data2::Tuple)
        #=
            cal_data1: calibrated channel 1 data of the 2 channels to be combined
            cal_data2: calibrated channel 2 data of the 2 channels to be combined
        
            This (legacy) function adds in quadrature 2 channels of calibrated data together
        
            authors: James M Cannon
            date of last modification: 02/09/24
        =#
        
        Combined_Data = deepcopy(cal_data1)
        #copy the timing data contained in the rest of the data tuple to preserve when the tuple is returned
    
        for i = 1:length(cal_data1[1])

            #check the lengths to be merged before merging
            #more robust solution desired for situations where data is off by only 1 second
            if length(cal_data1[1][i]) == length(cal_data2[1][i])
                Combined_Data[1][i] = sqrt.(cal_data1[1][i].^2 .+ cal_data2[1][i].^2)
                #add in quadrature (c = sqrt(a^2+b^2))
            end
        end
        return Combined_Data
        
    end

    function combine_2ch(cal_data1::fileData, cal_data2::fileData)
        #=
            cal_data1: calibrated channel 1 data of the 2 channels to be combined
            cal_data2: calibrated channel 2 data of the 2 channels to be combined
        
            This function adds in quadrature 2 channels of calibrated data together
            TODO add handling for checking each second of data to allow for situations where 1 channel has ~1 second of data missing
            authors: James M Cannon
            date of last modification: 04/25/24
        =#

        #more robust solution desired for situations where data is off by only 1 second
        if cal_data1.time == cal_data2.time
            Combined_Data = fileData(cal_data1.date,cal_data1.time,sqrt.(cal_data1.data.^2 .+ cal_data2.data.^2),cal_data1.Fc,cal_data1.Fs,-1)
            #add in quadrature (c = sqrt(a^2+b^2))
        else
            error("Unable to combine channels - timing data missmatch")
        end
    
        return Combined_Data
        
    end

    function combine_2ch(cal_vec1::Vector{fileData},cal_vec2::Vector{fileData})
        #=
            cal_vec1: vector of channel 1 calibrated amplitude data of type fileData
            cal_vec2: vector of channel 2 calibrated amplitude data of type fileData

            This function adds two channels in quadrature over a number of days
            TODO add robust data checking before passing to the single day version of the function
            authors: James M Cannon
            date of last modification: 06/03/24
        =#
        
        if length(cal_vec1) != length(cal_vec2)
            error("Unable to combine channels - different number of days")
        end
        Combined_Data = Vector{fileData}()
        for i in eachindex(cal_vec1)
            if cal_vec1[i].time == cal_vec2[i].time
                push!(Combined_Data, combine_2ch(cal_vec1[i],cal_vec2[i]))
            else
                println("Skipping ",cal_vec1[i].date," due to timing data mismatch")
            end
        end
        return Combined_Data
    end

    function label_maker(merged_data::Tuple,time_data::Tuple,number)
        #=
            legacy function
        =#
        line_labels = []
        unique_days = []
            for n in 1:length(time_data[3])-1
                if time_data[3][n+1]!=time_data[3][n]
                    append!(unique_days, time_data[3][n])
                end
            end
            n = length(time_data[3])
            m = length(unique_days)
            if time_data[3][n]!=unique_days[m]
                append!(unique_days, time_data[3][n])
            end
            for i in 1:length(merged_data[3])
                push!(line_labels, Date(merged_data[3][i],merged_data[4][i],unique_days[i]))
            end
            final_line_labels = []
            k = round(length(line_labels)/(number-1))
            l = round((Dates.value(last(line_labels))-Dates.value(line_labels[1]))/(number-1))
            j = collect(1:number)
            h = 0
            for i in eachindex(line_labels)
                if i == 1 || i == length(line_labels)
                    push!(final_line_labels, line_labels[i])
                    h+=1
                elseif (i == j[h]*k && i+5 < length(line_labels))
                    push!(final_line_labels, Date(Dates.UTD(Dates.value(line_labels[1])+j[h]*l)))
                    h+=1
                else
                    push!(final_line_labels, "")
                end
    
            end
        return final_line_labels,line_labels
    end

    function plot_data(axis_data1::Tuple, line_labels::Tuple, xlabel1, plot_title, xlim_fcn=[0, 24], xticks_fcn=(0:4:24))
        #=
            legacy function
        =#
	    n = length(axis_data1[1])
        base = Dates.value(line_labels[2][1]) #full value of first day
	    endpoint = Dates.value(last(line_labels[2])) #full value of last day
	
	    fig, ax = subplots()
	    cmap = matplotlib.cm.get_cmap("jet")
		  tick_positions = Vector{Float64}()
		  final_line_labels=[]
	
	    for i in 1:n
			#Line_color can be a number from 0 to 1, and divides the current days "value" by the last days "value". So the first day will have a cmap index of 0, and the last day will have a cmap index of 1
	        line_color = cmap((Dates.value(line_labels[2][i])-base) / (endpoint-base))

			#Same principal as the cmap index, but the ending tick of the colorbar corresponds to how many data points are represented by the colorbar. So, multiply by (n-1) so the index goes from 0 to (# of days plotted) instead of 0 to 1.
			    if line_labels[1][i] != ""
                    append!(tick_positions, ((Dates.value(line_labels[1][i])-base) / (endpoint-base))*(n-1))
                    push!(final_line_labels, line_labels[1][i])
                    ax.plot(axis_data1[2][i], axis_data1[1][i], color=line_color, 				label=line_labels[1][i], linewidth=0.5)
			    else
                    ax.plot(axis_data1[2][i],axis_data1[1][i], color=line_color, label="", linewidth=0.5)
			    end
	    end
	    ax.grid(true)
	
	    norm = matplotlib.colors.Normalize(vmin=0, vmax=n - 1)
	    sm = matplotlib.cm.ScalarMappable(cmap=cmap, norm=norm)
	    sm.set_array([])
	    cbar = fig.colorbar(sm, ax=ax)
	    cbar.set_label("Date")
        xticks(xticks_fcn)
        #xticks(0:1:24)
        ylabel(xlabel1)
        xlabel("Time (Hrs)")
        title(plot_title)
        xlim(xlim_fcn)
	    #set custom tick labels on the colorbar
	    cbar.set_ticks(tick_positions)
	    cbar.set_ticklabels(final_line_labels)
	
	    show()
	end

    @with_kw struct Plot_Options
        #=
            xlabel: x-axis label 
            ylabel: y-axis label
            title: plot title
            xlim: x-axis limits
            xticks: x-axis tick marker locations
            primary_color: primary color used in the plot
            grid: which gridlines to show (minor, major, both)

            This structure contains common plotting options to be reused by various plot functions

            authors: James M Cannon
            date of last modification: 12/14/23
        =#

        xlabel = "Time (Hrs)"
        ylabel
        title
        xlim = (0, 24)
        xticks = (0:4:24)
        ylim = []
        yticks = []
        primary_color = "#3CA0FA"
        minorgrid = true
    end

    function plot_day(axis_data_fcn::Vector; line_label="",opts::Plot_Options)
        #=
            legacy function

            axis_data_fcn: vector of [1][:] data and [2][:] timestamps
            line_label: desired label for line (default of "")
            opts: Plot_Options structure containing various options for modifying a plot

            This function plots a single day of narrowband data
        
            authors: James M Cannon
            date of last modification: 12/14/23
        =#

        plt.plot(axis_data_fcn[2][:],axis_data_fcn[1][:],color=opts.primary_color, label=line_label,linewidth=0.5)
        plt.grid(which = opts.grid)
        plt.xticks(opts.xticks)
        plt.ylabel(opts.ylabel)
        plt.xlabel(opts.xlabel)
        plt.title(opts.title)
        if !isempty(opts.ylim)
            plt.ylim(opts.ylim)
            plt.yticks(opts.yticks)
        end
        plt.xlim(opts.xlim)
        plt.show()
    end

    function plot_day(site_data::fileData; line_label="",opts::Plot_Options)
        #=
            site_data: fileData structure containing the day of data of interest
            line_label: desired label for line (default of "")
            opts: Plot_Options structure containing various options for modifying a plot

            This function plots a single day of narrowband data

            TODO make sure opts is an optional argument that, if not passed, is pulled using default plot options values.
        
            authors: James M Cannon
            date of last modification: 08/05/24
        =#

        p = plot(site_data.time./(3600),site_data.data,color=opts.primary_color, label=line_label,linewidth=0.5)
        #xticks!(opts.xticks)
        #ylabel!(opts.ylabel)
        xlabel!(opts.xlabel)
        title!(opts.title)
        if !isempty(opts.ylim)
            ylims!(opts.ylim)
            yticks!(opts.yticks)
        end
        xlims!(opts.xlim)
        display(p)
        return p
    end

    function plot_multi_site(axis_data_fcn::Vector; line_labels="",opts::Plot_Options)
        #=
            legacy function

            axis_data_fcn: vector of [n][1][:] data and [n][2][:] timestamps where n is the number of sites
            line_labels: desired labels for each of n lines (default of "")
            opts: Plot_Options structure containing various options for modifying a plot

            This function plots a single day of narrowband data across multiple sites
        
            authors: James M Cannon
            date of last modification: 12/15/23
        =#
        count=1
        for i in axis_data_fcn
            plt.plot(i[2][:],i[1][:],linewidth=0.5,color=opts.primary_color[count])
            count=count+1
        end
        plt.grid(which = opts.grid)
        plt.xticks(opts.xticks)
        plt.ylabel(opts.ylabel)
        plt.xlabel(opts.xlabel)
        plt.title(opts.title)
        plt.xlim(opts.xlim)
        if !isempty(opts.ylim)
            plt.ylim(opts.ylim)
            plt.yticks(opts.yticks)
        end
        if !isempty(line_labels)
            plt.legend(line_labels)
        end
        plt.show()
    end

    #TODO Add a new plot_multi_site function to use the new fileData structure
    #TODO comment and double check the unwrap function. Perhaps make changes to use fileData structure? Might be uneccesary as the call can simply be fileData.data = unwrap(fileData.data)

    function unwrap(phase::Vector{})
        unwrapped_phase = copy(phase)
        unwrapped_phase[1] = phase[1]

        for i in 2:length(phase) #eachindex() doesn't work here and I don't know why
            diff = phase[i] - phase[i - 1]
            if diff > 180 #if jump goes from neg to pos
                phase[i] = phase[i] - 360 * ceil((diff - 180) / 360)
                #phase[i] = -180 - (180-phase[i])
            elseif diff < -180 #if jump goes from pos to neg
                phase[i] = phase[i] + 360 * ceil((-diff - 180) / 360)
                #phase[i] = 180 - (-180-phase[i])
            else
                phase[i] = phase[i]
            end
        end

        return phase
    end

    function clean_phase(tx_path::AbstractString,tx::AbstractString,day::fileData)
        rx = "_EW_B"
        in_pat = Regex(join([Dates.format(day.date,"yymmdd"),".*",tx*rx]))
        
        base_day = read_data(read_multiple_mat_files(tx_path,in_pat))

        base_day_struct = base_day[1]

        out_pha=[]

        if length(base_day)>1
            error("For date ",date, " multiple VLF data structures created\n")
        else
        
            tx_on = tx_On(tx_path,tx,day.date)
            off_idxes=findall(x->x==0,tx_on.data)
            off_times=tx_on.time[off_idxes]
            if length(off_times)>1
                for time in off_times
                    if !isnothing(findfirst(x->x==time,day.time))
                        deleteat!(day.data,findfirst(x->x==time,day.time))
                        deleteat!(day.time,findfirst(x->x==time,day.time))
                    end
                    if !isnothing(findfirst(x->x==time,base_day_struct.time))
                        deleteat!(base_day_struct.data,findfirst(x->x==time,base_day_struct.time))
                        deleteat!(base_day_struct.time,findfirst(x->x==time,base_day_struct.time))
                    end 
                end
            end

            if length(day.time) != length(base_day_struct.time)
                for time in day.time
                    if !isnothing(findfirst(x->x==time,base_day_struct.time))
                        append!(out_pha,(day.data[findfirst(x->x==time,day.time)] - base_day_struct.data[findfirst(x->x==time,base_day_struct.time)]))
                    end 
                end
                if length(out_pha)!=length(day.time)
                    println("Mismatched phase and time lengths in cleaning phase")
                end
            else
                out_pha=day.data - base_day_struct.data
            end
            return(fileData(day.date,day.time,out_pha,day.Fc,day.Fs,day.adc_channel_number))
        end

    end


    function tx_On(folder_path::AbstractString, tx::AbstractString, date::Date)
        #=
            folder_path: path to the directory where the tx data is housed
            tx: the transmitter in question
            date: date of lookup

            This function checks which seconds the tx was on for the date requested, returned as a fileData structure with data either 0 (off) or 1 (on)
        
            TODO add NML limits
            TODO add ability to check 50Hz instead of just 1Hz

            authors: James M Cannon
            date of last modification: 08/02/24
        =#
        NLK_EW_limit=6000
        NML_EW_limit = 2000
        if tx == "NLK"
            limit = NLK_EW_limit
            rx = "_EW_A"
        elseif tx == "NML"
            limit = NML_EW_limit
            rx = "_EW_A"
        else
            error("Unknown limit for TX: ", tx)
        end
    
        in_pat = Regex(join([Dates.format(date,"yymmdd"),".*",tx*rx]))
        
        cur_day = read_data(read_multiple_mat_files(folder_path,in_pat))

        cur_day_struct = cur_day[1]
        time_vec = 0:1/cur_day_struct.Fs:(86400 - (1/cur_day_struct.Fs))
        out_vec = zeros(length(time_vec))

        if length(cur_day)>1
            println("For date ",date, " multiple VLF data structures created\n")
        else
        
            for t in eachindex(time_vec)
                idx = findfirst(x -> x==time_vec[t],cur_day_struct.time)
                if !isnothing(idx) 
                    if cur_day_struct.data[idx]>limit
                        out_vec[t]=1
                    end
                end
            end

        end
    
        out = VLF.fileData(date,time_vec,out_vec,cur_day_struct.Fc,cur_day_struct.Fs,cur_day_struct.adc_channel_number)
    
        return(out)
    end

    function stitchPhase(days::Vector{fileData};tolerance::Number=10,unwrap=true)
        output = Vector{fileData}()
        for day in days
            append!(output,[stitchPhase(day,tolerance=tolerance,unwrap=unwrap)])
        end
        return output
    end


    function stitchPhase(day::fileData;tolerance::Number=10,unwrap=true)

        #TODO find a general expression to check n x 90 degrees

        if unwrap
            phase = VLF.unwrap(day.data)
        else
            phase = day.data
        end

        for i in 1:length(day.time)-1
            if (day.time[i+1]-day.time[i])>(day.Fs)
                del_phase = phase[i+1] - phase[i]

                if ((1*90)-tolerance< del_phase <(1*90)+tolerance)
                    correction = -90
                elseif ((2*90)-tolerance< del_phase < (2*90)+tolerance)
                    correction = -180
                elseif ((3*90)-tolerance< del_phase < (3*90)+tolerance)
                    correction = -270
                elseif ((-1*90)-tolerance< del_phase < (-1*90)+tolerance)
                    correction = 90
                elseif ((-2*90)-tolerance< del_phase < (-2*90)+tolerance)
                    correction = 180
                elseif ((-3*90)-tolerance< del_phase < (-3*90)+tolerance)
                    correction = 270
                else
                    correction = 0
                end
                phase[i+1:end] = phase[i+1:end].+correction
           end
        end
        return fileData(day.date,day.time,phase,day.Fc,day.Fs,day.adc_channel_number)
    end
    
    function getVLFdata(folder_path,Transmitter_code,date,cal_file;unwrap_phase=true,legacy_flag)

        if legacy_flag
            EW = "_100"
            NS = "_101"
        else
            EW = "_EW_"
            NS = "_NS_"
        end
    
        date_str = Dates.format(Date(date),"yymmdd")
    
        EW_pha_in_pat = Regex(join([date_str,".*",Transmitter_code*EW*"B"]))
        EW_pha_days = read_data(read_multiple_mat_files(folder_path,EW_pha_in_pat))
    
        NS_pha_in_pat = Regex(join([date_str,".*",Transmitter_code*NS*"B"]))
        NS_pha_days = read_data(read_multiple_mat_files(folder_path,NS_pha_in_pat))
    
        EW_amp_in_pat = Regex(join([date_str,".*",Transmitter_code*EW*"A"]))
        EW_amp_days = calibrate_NB(read_data(read_multiple_mat_files(folder_path,EW_amp_in_pat)),cal_file=cal_file)
    
        NS_amp_in_pat = Regex(join([date_str,".*",Transmitter_code*NS*"A"]))
        NS_amp_days = calibrate_NB(read_data(read_multiple_mat_files(folder_path,NS_amp_in_pat)),cal_file=cal_file)
    
        amp_Combined_Data = combine_2ch(NS_amp_days,EW_amp_days)
    
        NS_stitched_phase = stitchPhase(NS_pha_days,unwrap=unwrap_phase)
        EW_stitched_phase = stitchPhase(EW_pha_days,unwrap=unwrap_phase)
    
        return amp_Combined_Data, NS_stitched_phase, EW_stitched_phase
    end
    
    function getVLFdata(folder_path,Transmitter_code,date,cal_file;unwrap_phase=true,Phase_Baseline_Path=nothing,tolerance=10,legacy_flag=false)
    
        if legacy_flag
            EW = "_100"
            NS = "_101"
        else
            EW = "_EW_"
            NS = "_NS_"
        end
    
        if isnothing(Phase_Baseline_Path)
            if Transmitter_code == "NLK"
                Phase_Baseline_Path = "L:\\VLF\\AVID\\ARL\\Narrowband\\"
            elseif Transmitter_code == "NML"
                Phase_Baseline_Path = "L:\\VLF\\AVID\\LAM\\Narrowband\\"
            else
                error("Unknown transmitter, ",Transmitter_code)
            end
            year = Dates.format(Date(date),"yyyy")
            month = Dates.format(Date(date),"mm") *"_"* Dates.monthname(Date(date))
            Phase_Baseline_Path = Phase_Baseline_Path*year*"\\"*month*"\\"
        end
    
        date_str = Dates.format(Date(date),"yymmdd")
    
        EW_pha_in_pat = Regex(join([date_str,".*",Transmitter_code*EW*"B"]))
        EW_pha_days = read_data(read_multiple_mat_files(folder_path,EW_pha_in_pat))
    
        NS_pha_in_pat = Regex(join([date_str,".*",Transmitter_code*NS*"B"]))
        NS_pha_days = read_data(read_multiple_mat_files(folder_path,NS_pha_in_pat))
    
        EW_amp_in_pat = Regex(join([date_str,".*",Transmitter_code*EW*"A"]))
        EW_amp_days = calibrate_NB(read_data(read_multiple_mat_files(folder_path,EW_amp_in_pat)),cal_file=cal_file)
    
        NS_amp_in_pat = Regex(join([date_str,".*",Transmitter_code*NS*"A"]))
        NS_amp_days = calibrate_NB(read_data(read_multiple_mat_files(folder_path,NS_amp_in_pat)),cal_file=cal_file)
    
        amp_Combined_Data = combine_2ch(NS_amp_days,EW_amp_days)
    
        NS_clean_pha = VLF.clean_phase.(Phase_Baseline_Path,Transmitter_code,NS_pha_days)
        EW_clean_pha = VLF.clean_phase.(Phase_Baseline_Path,Transmitter_code,EW_pha_days)
    
        NS_stitched_phase = stitchPhase(NS_clean_pha,unwrap=unwrap_phase,tolerance=tolerance)
        EW_stitched_phase = stitchPhase(EW_clean_pha,unwrap=unwrap_phase,tolerance=tolerance)
    
        return amp_Combined_Data, NS_stitched_phase, EW_stitched_phase
    end
    
    

end

