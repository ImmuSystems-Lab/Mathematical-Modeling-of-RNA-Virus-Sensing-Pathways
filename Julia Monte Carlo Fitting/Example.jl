using DifferentialEquations,ParameterizedFunctions, DiffEqParamEstim #DiffEq
using RecursiveArrayTools, StatsBase,Distributions #Vector of Arrays and stats
using StatsPlots, CSV, DataFrames,Printf,Dierckx,ProgressMeter
using AverageShiftedHistograms, DelimitedFiles
###########################
#ToDo
#Implement python emcee-like prior probability function to enforce parameter bounds
###########################
cd()
cd(".\\Documents\\GitHub\\6StateMCMC\\")
#Import the MCMC solver
include("main.jl")
#Import error function
include("LossFunction.jl")

function Model!(dy,y,par,t)
  #IFN, ODE 1 parameters
  k11=0 #PR8, RIGI is assumed antagonized so k11=0. dNS1PR8, RIG-I is active so k11=1E5.
  n=3 #Fixed Hill-like kinetic order for stability
  RIGI=1 #Future use, could have production and decay of RIG-I protein within the cell
  k12=par[1]
  k13=par[2]
  k14=par[3]
  #IFN_env, ODE 2 parameters
  k21=par[4]
  tau2=par[5]
  #STATP, ODE 3 parameters
  k31=par[6]
  k32=par[7]
  k33=par[8]
  #IRF7, ODE 4 parameters
  k41=par[9]
  k42=par[10]
  #IRF7P, ODE 5 parameters
  k51=par[11]
  #Cells, ODE 6 parameters
  k61=par[12]
  #Virus, ODE 7 parameters
  k71=par[13]
  k72=par[14]
  k73=par[15]

  #ODE System
  dy[1]=y[6]*(k11*RIGI*y[7]+(k12*y[7]^n)/(k13+y[7]^n)+k14*y[5])-k21*y[1]
  dy[2]=k21*y[1]-tau2*y[2]
  dy[3]=(k31*y[2]*y[6])/(k32+k33*y[2])-0.3*y[3]
  dy[4]=y[6]*(k41*y[3]+k42*y[5])-0.3*y[4]
  dy[5]=k51*y[4]-0.3*y[5]
  dy[6]=-k61*y[6]*y[7]
  dy[7]=(k71*y[6]*y[7])/(1+k72*(y[2]*7E-5))-k73*y[7] #Note unit correction for TCID50 and IFNe
end

#parNames = ["a","b","c"]
#parNum = length(parNames)
stateNames = ["IFN","IFNe","STATP","IRF7","IRF7P","Live Cells","Virus"]
parNum = 15

#Define information for ODE model
p=rand(parNum) #Parameter values
u0 = [0, 0, 0, 0.72205, 0, 1, 6.9e-8] #Shifted Initial Conditions
tspan = (0,24.0) #Time (start, end)
shift= [7.939, 0, 12.2075, 13.4271, 0, 0, 0] #Noise shift on data
#Contruct the ODE Problem
prob = ODEProblem(Model!,u0,tspan,p)
alg = Vern7()   #ODE solver

#Solve for the "True" solution
sol = solve(prob,alg)

## Generate data

data = CSV.read(".\\data\\PR8.csv")
t = convert(Array,data[:Time])
mock = CSV.read(".\\data\\Control.csv")
titer = CSV.read(".\\data\\ViralTiters.csv")
t_titer=convert(Array,titer[:Time])

removeCol = [:Experiment :Time :IFN_env] #Strip time and IFN_env from data
for col in removeCol
  deletecols!(data,col)
  deletecols!(mock,col)
end

removeCol = [:Experiment :Time] #Strip time from viral titers
for col in removeCol
  deletecols!(titer,col)
end

data = convert(Matrix,data)
mock = convert(Matrix,mock)
titer = convert(Matrix,titer)

#Data points being measured
measured = [1,3,4]

## Supply prior distributions
priors = fill(Uniform(0,1), parNum)
parBounds = fill([0.0, Inf], parNum) #Fill bounds with 0/inf
#Modify bounds with known values
parBounds[5]=Float64[0.0, 2.5]
parBounds[12]=Float64[0.0, 1.0]
parBounds[15]=Float64[0.0, 0.5]

lossFunc = LossLog(t,t_titer,data,measured,mock,titer,shift)

sampleNum = Int(1e9)

result = ptMCMC(prob,alg,priors,parBounds,lossFunc,sampleNum)
bestPars= dropdims(permutedims(result[1], [1, 3, 2])[argmax(result[2],dims=1),:],dims=1)
pNew=bestPars[1,:]


CSV.write(".\\results\\chainparams.csv",DataFrame(result[1][:,:,1]))

open(".\\results\\acceptRatio.csv","a") do io #Write out acceptance ratios
  writedlm(io,result[3][:,1])
end
open(".\\results\\energy.csv","a") do io #Write out loss function values
  writedlm(io,result[2][:,1])
end

#Pull best results from the best chain
bestPars= dropdims(permutedims(result[1], [1, 3, 2])[argmax(result[2],dims=1),:],dims=1)
bestChains = [remake(prob;p=bestPars[i,:]) for i=1:size(bestPars,1)]
chainSols = [solve(problem,alg) for problem in bestChains]

###############
ODEplots = Vector(undef,length(u0))

mockSplines = [Spline1D(t,mock[:,i];k=1) for i=1:size(mock,2)]

plotRecipe = (t,x,i,j) -> plot(t,x,label="Chain $j",title=stateNames[i],framestyle=:box,yformatter=y->"$(@sprintf("%.0e",y))",legend=false)

Lfc(c,m) = @. log2(c) - log2(m)
LfcShift(c,m,s) = @. log2(c+s) - log2(m)
#loop through states
for i in eachindex(u0)

#Make the first plot for the first chain
  if i ∈ measured
      midx = findfirst(x->x==i,measured)
      #logScaledSim = Lfc(chainSols[1][i,:], mockSplines[midx](chainSols[1].t))
      logScaledSim = LfcShift(chainSols[1][i,:], mockSplines[midx](chainSols[1].t), shift[i])
      ODEplots[i] = plotRecipe(chainSols[1].t,logScaledSim,i,1)
      scatter!(t,data[:,findfirst(x->x==i,measured)],label="Data: "*stateNames[i])
  else
      ODEplots[i] = plotRecipe(chainSols[1].t,chainSols[1][i,:],i,1)
  end

#Loop through and add the rest of the chains
  for j=2:length(chainSols)
    if i ∈ measured
      midx = findfirst(x->x==i,measured)
      #logScaledSim = Lfc(chainSols[j][i,:], mockSplines[midx](chainSols[j].t))
      logScaledSim = LfcShift(chainSols[j][i,:], mockSplines[midx](chainSols[j].t), shift[i])
      plot!(chainSols[j].t,logScaledSim,label="Chain $j")
    else
      plot!(chainSols[j].t,chainSols[j][i,:],label="Chain $j")
    end
  end

end

datafitPlot = plot(ODEplots...,size=(1920,1080))

savefig(datafitPlot,".\\plots\\DataFit.pdf")

#Posterior
HistData = [plot(ash(result[1][1:end,i,1]),title="Par $i") for i=1:parNum]
histPlot=plot(HistData...,legend=false,size=(1920,1080))

savefig(histPlot,".\\plots\\histPlot.pdf")

logPostPlot = plot(result[2],legend =false,title="logPosterior")
savefig(logPostPlot,".\\plots\\logPostPlot.pdf")

#acceptance Rate
AcceptPlot = plot(result[3],legend =false,title="Acceptance Rate")
savefig(AcceptPlot,".\\plots\\AcceptPlot.pdf")