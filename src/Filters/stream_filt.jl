typealias PFB{T} Matrix{T}          # polyphase filter bank

abstract Filter
abstract FIRKernel{T}

# Single rate FIR kernel
type FIRStandard{T} <: FIRKernel{T}
    h::Vector{T}
    hLen::Int
end

function FIRStandard(h::Vector)
    h    = flipdim(h, 1)
    hLen = length(h)
    FIRStandard(h, hLen)
end


# Interpolator FIR kernel
type FIRInterpolator{T} <: FIRKernel{T}
    pfb::PFB{T}
    interpolation::Int
    Nϕ::Int
    tapsPerϕ::Int
end

function FIRInterpolator(h::Vector, interpolation::Integer)
    pfb           = taps2pfb( h, interpolation )
    tapsPerϕ, Nϕ  = size(pfb)
    interpolation = interpolation
    FIRInterpolator(pfb, interpolation, Nϕ, tapsPerϕ)
end


# Decimator FIR kernel
type FIRDecimator{T} <: FIRKernel{T}
    h::Vector{T}
    hLen::Int
    decimation::Int
    inputDeficit::Int
end

function FIRDecimator(h::Vector, decimation::Integer)
    h            = flipdim(h, 1)
    hLen         = length(h)
    inputDeficit = 1
    FIRDecimator(h, hLen, decimation, inputDeficit)
end


# Rational resampler FIR kernel
type FIRRational{T}  <: FIRKernel{T}
    pfb::PFB{T}
    ratio::Rational{Int}
    Nϕ::Int
    ϕIdxStepSize::Int
    tapsPerϕ::Int
    ϕIdx::Int
    inputDeficit::Int
end

function FIRRational(h::Vector, ratio::Rational)
    pfb          = taps2pfb(h, num(ratio))
    tapsPerϕ, Nϕ = size(pfb)
    ϕIdxStepSize = mod(den(ratio), num(ratio))
    ϕIdx         = 1
    inputDeficit = 1
    FIRRational(pfb, ratio, Nϕ, ϕIdxStepSize, tapsPerϕ, ϕIdx, inputDeficit)
end


#
# Arbitrary resampler FIR kernel
#
# This kernel is different from the others in that it has two polyphase filtlter banks.
# The the second filter bank, dpfb, is the derivative of pfb. The purpose of this is to
# allow us to compute two y values, yLower & yUpper, whitout having to advance the input
# index by 1. It makes the kernel simple by not having to store extra state in the case
# when where's at the last polphase branch and the last available input sample. By using
# a derivitive filter, we can always compute the output in that scenario.
# See section 7.6.1 in [1] for a better explanation.

type FIRArbitrary{T} <: FIRKernel{T}
    rate::Float64
    pfb::PFB{T}
    dpfb::PFB{T}
    Nϕ::Int
    tapsPerϕ::Int
    ϕAccumulator::Float64
    ϕIdx::Int
    α::Float64
    Δ::Float64
    inputDeficit::Int
    xIdx::Int
end

function FIRArbitrary( h::Vector, rate::Real, Nϕ::Integer )
    dh           = [diff(h); zero(eltype(h))]
    pfb          = taps2pfb(h,  Nϕ)
    dpfb         = taps2pfb(dh, Nϕ)
    tapsPerϕ     = size(pfb, 1)
    ϕAccumulator = 1.0
    ϕIdx         = 1
    α            = 0.0
    Δ            = Nϕ/rate
    inputDeficit = 1
    xIdx         = 1
    FIRArbitrary( rate, pfb, dpfb, Nϕ, tapsPerϕ, ϕAccumulator, ϕIdx, α, Δ, inputDeficit, xIdx )
end


# FIRFilter - the kernel does the heavy lifting
type FIRFilter{Tk<:FIRKernel} <: Filter
    kernel::Tk
    history::Vector
    historyLen::Int
    h::Vector
end

# Constructor for single-rate, decimating, interpolating, and rational resampling filters
function FIRFilter(h::Vector, resampleRatio::Rational = 1//1)
    interpolation = num(resampleRatio)
    decimation    = den(resampleRatio)
    historyLen    = 0

    if resampleRatio == 1                                     # single-rate
        kernel     = FIRStandard(h)
        historyLen = kernel.hLen - 1
    elseif interpolation == 1                                 # decimate
        kernel     = FIRDecimator(h, decimation)
        historyLen = kernel.hLen - 1
    elseif decimation == 1                                    # interpolate
        kernel     = FIRInterpolator(h, interpolation)
        historyLen = kernel.tapsPerϕ - 1
    else                                                      # rational
        kernel     = FIRRational(h, resampleRatio)
        historyLen = kernel.tapsPerϕ - 1
    end

    history = zeros(historyLen)

    FIRFilter(kernel, history, historyLen, h)
end

# Constructor for arbitrary resampling filter (polyphase interpolator w/ intra-phase linear interpolation)
function FIRFilter(h::Vector, rate::FloatingPoint, Nϕ::Integer=32)
    rate > 0.0 || error("rate must be greater than 0")
    kernel     = FIRArbitrary(h, rate, Nϕ)
    historyLen = kernel.tapsPerϕ - 1
    history    = zeros(historyLen )
    FIRFilter(kernel, history, historyLen, h)
end


#
# reset! filter and its kernel to an initial state
#

# Generic case for FIRInterpolator and FIRStandard
function reset!(kernel::FIRKernel)
    kernel
end

function reset!(kernel::FIRRational)
    kernel.ϕIdx         = 1
    kernel.inputDeficit = 1
    kernel
end

function reset!(kernel::FIRDecimator)
    kernel.inputDeficit = 1
    kernel
end

function reset!(kernel::FIRArbitrary)
    kernel.ϕAccumulator = 1.0
    kernel.ϕIdx         = 1
    kernel.α            = 0.0
    kernel.inputDeficit = 1
    kernel.xIdx         = 1
    kernel
end

# For FIRFilter, set history vector to zeros of same type and required length
function reset!(self::FIRFilter)
    self.history = zeros( eltype( self.history ), self.historyLen )
    reset!( self.kernel )
    self
end

#
# taps2 pfb
#
# Converts a vector of coefficients to a matrix. Each column is a filter.
# NOTE: also flips the matrix up/down so computing the dot product of a
#       column with a signal vector is more efficient (since filter is convolution)
# Appends zeros if necessary.
# Example:
#   julia> taps2pfb( [1:9], 4 )
#   3x4 Array{Int64,2}:
#    9  0  0  0
#    5  6  7  8
#    1  2  3  4
#
#  In this example, the first phase, or ϕ, is [9, 5, 1].

function taps2pfb{T}( h::Vector{T}, Nϕ::Integer )
    hLen     = length( h )
    tapsPerϕ = ceil(Int, hLen/Nϕ)
    pfbSize  = tapsPerϕ * Nϕ
    pfb      = Array( T, tapsPerϕ, Nϕ )
    hIdx     = 1

    for rowIdx in tapsPerϕ:-1:1, colIdx in 1:Nϕ
        tap = hIdx > hLen ? zero(T) : h[hIdx]
        @inbounds pfb[rowIdx,colIdx] = tap
        hIdx += 1
    end

    return pfb
end


#
# Calculates the resulting length of a multirate filtering operation, given a
#   FIRFilter{FIRRational} object and an input vector
#
# ( It's hard to explain how this works without a diagram )
#

function outputlength(inputlength::Integer, ratio::Rational, initialϕ::Integer )
    interpolation = num(ratio)
    decimation    = den(ratio)
    outLen        = ((inputlength * interpolation) - initialϕ + 1) / decimation
    ceil(Int, outLen)
end

function outputlength(kernel::FIRStandard, inputlength::Integer)
    inputlength
end

function outputlength(kernel::FIRInterpolator, inputlength::Integer)
    kernel.interpolation * inputlength
end

function outputlength(kernel::FIRDecimator, inputlength::Integer)
    outputlength(inputlength-kernel.inputDeficit+1, 1//kernel.decimation, 1)
end

function outputlength(kernel::FIRRational, inputlength::Integer)
    outputlength(inputlength-kernel.inputDeficit+1, kernel.ratio, kernel.ϕIdx)
end

function outputlength( kernel::FIRArbitrary, inputlength::Integer )
    ceil(Int, (inputlength-kernel.inputDeficit+1) * kernel.rate)
end

function outputlength(self::FIRFilter, inputlength::Integer)
    outputlength(self.kernel, inputlength)
end


#
# Calculates the input length of a multirate filtering operation,
# given the output length
#

function inputlength(outputlength::Int, ratio::Rational, initialϕ::Integer)
    interpolation = num(ratio)
    decimation    = den(ratio)
    inLen         = (outputlength * decimation + initialϕ - 1) / interpolation
    ceil(Int, inLen)
end

function inputlength(kernel::FIRStandard, outputlength::Integer)
    outputlength
end

function inputlength(kernel::FIRInterpolator, outputlength::Integer)
    inputlength(outputlength, kernel.interpolation//1, 1)
end

function inputlength(kernel::FIRDecimator, outputlength::Integer)
    inLen  = inputlength(outputlength, 1//kernel.decimation, 1)
    inLen += kernel.inputDeficit - 1
end

function inputlength(kernel::FIRRational, outputlength::Integer)
    inLen  = inputlength(outputlength, kernel.ratio, kernel.ϕIdx)
    inLen += kernel.inputDeficit - 1
end

# TODO: figure out why this fails. Might be fine, but the filter operation might not being stepping through the phases correcty.
function inputlength(kernel::FIRArbitrary, outputlength::Integer)
    inLen  = ifloor(outputlength/kernel.rate)
    inLen += kernel.inputDeficit - 1
end

function inputlength(self::FIRFilter, outputlength::Integer)
    inputlength(self.kernel, outputlength)
end


#
# Single rate filtering
#

function Base.filt!{Tb,Th,Tx}(buffer::Vector{Tb}, self::FIRFilter{FIRStandard{Th}}, x::Vector{Tx})
    kernel              = self.kernel
    history::Vector{Tx} = self.history
    bufLen              = length(buffer)
    xLen                = length(x)
    criticalIdx         = min(kernel.hLen, bufLen)
    inputIdx            = 1
    bufIdx              = 0

    bufLen >= xLen || error("buffer length must be >= x length")

    while inputIdx <= xLen
        bufIdx += 1
        if inputIdx < kernel.hLen
            accumulator = unsafe_dot(kernel.h, history, x, inputIdx)
        else
            accumulator = unsafe_dot( kernel.h, x, inputIdx )
        end
        buffer[bufIdx] = accumulator
        inputIdx += 1
    end

    self.history = shiftin!(history, x)

    return bufIdx
end

function Base.filt{Th,Tx}(self::FIRFilter{FIRStandard{Th}}, x::Vector{Tx})
    bufLen         = outputlength(self, length(x))
    buffer         = Array(promote_type(Th,Tx), bufLen)
    samplesWritten = filt!(buffer, self, x)

    samplesWritten == bufLen || resize!( buffer, samplesWritten)

    return buffer
end


#
# Interpolation
#

function Base.filt!{Tb,Th,Tx}( buffer::Vector{Tb}, self::FIRFilter{FIRInterpolator{Th}}, x::Vector{Tx} )
    kernel              = self.kernel
    history::Vector{Tx} = self.history
    interpolation       = kernel.interpolation
    xLen                = length(x)
    bufLen              = length(buffer)
    inputIdx            = 1
    bufIdx              = 0
    ϕIdx                = 1

    bufLen >= outputlength(self, xLen) || error("length( buffer ) must be >= interpolation * length(x)")

    while inputIdx <= xLen
        bufIdx += 1

        if inputIdx < kernel.tapsPerϕ
            accumulator = unsafe_dot(kernel.pfb, ϕIdx, history, x, inputIdx)
        else
            accumulator = unsafe_dot( kernel.pfb, ϕIdx, x, inputIdx )
        end

        buffer[bufIdx]   = accumulator
        (ϕIdx, inputIdx) = ϕIdx == kernel.Nϕ ? (1, inputIdx+1) : (ϕIdx+1, inputIdx)
    end

    self.history = shiftin!(history, x)

    return bufIdx
end

function Base.filt{Th,Tx}(self::FIRFilter{FIRInterpolator{Th}}, x::Vector{Tx})
    bufLen         = outputlength(self, length(x))
    buffer         = Array(promote_type(Th,Tx), bufLen)
    samplesWritten = filt!(buffer, self, x)

    samplesWritten == bufLen || resize!( buffer, samplesWritten)

    return buffer
end


#
# Rational resampling
#

function Base.filt!{Tb,Th,Tx}(buffer::Vector{Tb}, self::FIRFilter{FIRRational{Th}}, x::Vector{Tx})
    kernel              = self.kernel
    history::Vector{Tx} = self.history
    xLen                = length(x)
    bufLen              = length(buffer)
    bufIdx              = 0

    if xLen < kernel.inputDeficit
        self.history = shiftin!(history, x)
        kernel.inputDeficit -= xLen
        return bufIdx
    end

    outLen = outputlength(xLen-kernel.inputDeficit+1, kernel.ratio, kernel.ϕIdx)
    bufLen >= outLen || error("buffer is too small")

    interpolation       = num(kernel.ratio)
    decimation          = den(kernel.ratio)
    inputIdx            = kernel.inputDeficit

    while inputIdx <= xLen
        bufIdx += 1

        if inputIdx < kernel.tapsPerϕ
            accumulator = unsafe_dot(kernel.pfb, kernel.ϕIdx, history, x, inputIdx)
        else
            accumulator = unsafe_dot(kernel.pfb, kernel.ϕIdx, x, inputIdx)
        end

        buffer[bufIdx]  = accumulator
        inputIdx       += div(kernel.ϕIdx + decimation - 1, interpolation)
        ϕIdx            = kernel.ϕIdx + kernel.ϕIdxStepSize
        kernel.ϕIdx     = ϕIdx > interpolation ? ϕIdx - interpolation : ϕIdx
    end

    kernel.inputDeficit = inputIdx - xLen
    self.history        = shiftin!(history, x)

    return bufIdx
end

function Base.filt{Th,Tx}(self::FIRFilter{FIRRational{Th}}, x::Vector{Tx})
    bufLen         = outputlength(self, length(x))
    buffer         = Array(promote_type(Th,Tx), bufLen)
    samplesWritten = filt!(buffer, self, x)

    samplesWritten == bufLen || resize!( buffer, samplesWritten)

    return buffer
end


#
# Decimation
#

function Base.filt!{Tb,Th,Tx}(buffer::Vector{Tb}, self::FIRFilter{FIRDecimator{Th}}, x::Vector{Tx})
    kernel              = self.kernel
    xLen                = length(x)
    history::Vector{Tx} = self.history
    bufIdx              = 0

    if xLen < kernel.inputDeficit
        self.history = shiftin!(history, x)
        kernel.inputDeficit -= xLen
        return bufIdx
    end

    outLen              = outputlength(self, xLen)
    inputIdx            = kernel.inputDeficit

    while inputIdx <= xLen
        bufIdx += 1

        if inputIdx < kernel.hLen
            accumulator = unsafe_dot(kernel.h, history, x, inputIdx)
        else
            accumulator = unsafe_dot(kernel.h, x, inputIdx)
        end

        @inbounds buffer[bufIdx] = accumulator
        inputIdx                += kernel.decimation
    end

    kernel.inputDeficit = inputIdx - xLen
    self.history        = shiftin!(history, x)

    return bufIdx
end

function Base.filt{Th,Tx}(self::FIRFilter{FIRDecimator{Th}}, x::Vector{Tx})
    bufLen         = outputlength(self, length(x))
    buffer         = Array(promote_type(Th,Tx), bufLen)
    samplesWritten = filt!(buffer, self, x)

    samplesWritten == bufLen || resize!( buffer, samplesWritten)

    return buffer
end


#
# Arbitrary resampling
#
# Updates FIRArbitrary state. See Section 7.5.1 in [1].
#   [1] uses a phase accumilator that increments by Δ (Nϕ/rate)

function update(kernel::FIRArbitrary)
    kernel.ϕAccumulator += kernel.Δ

    if kernel.ϕAccumulator > kernel.Nϕ
        kernel.xIdx        += div(kernel.ϕAccumulator-1, kernel.Nϕ)
        kernel.ϕAccumulator = mod(kernel.ϕAccumulator-1, kernel.Nϕ) + 1
    end

    kernel.ϕIdx = floor(Int, kernel.ϕAccumulator)
    kernel.α    = kernel.ϕAccumulator - kernel.ϕIdx
end

function Base.filt!{Tb,Th,Tx}(buffer::Vector{Tb}, self::FIRFilter{FIRArbitrary{Th}}, x::Vector{Tx})
    kernel              = self.kernel
    pfb                 = kernel.pfb
    dpfb                = kernel.dpfb
    xLen                = length(x)
    bufIdx              = 0
    history::Vector{Tx} = self.history

    # Do we have enough input samples to produce one or more output samples?
    if xLen < kernel.inputDeficit
        self.history = shiftin!(history, x)
        kernel.inputDeficit -= xLen
        return bufIdx
    end

    # Skip over input samples that are not needed to produce output results.
    # We do this by seting inputIdx to inputDeficit which was calculated in the previous run.
    # InputDeficit is set to 1 when instantiation the FIRArbitrary kernel, that way the first
    #   input always produces an output.
    kernel.xIdx = kernel.inputDeficit

    while kernel.xIdx <= xLen
        bufIdx += 1

        if kernel.xIdx < kernel.tapsPerϕ
            yLower = unsafe_dot(pfb,  kernel.ϕIdx, history, x, kernel.xIdx)
            yUpper = unsafe_dot(dpfb, kernel.ϕIdx, history, x, kernel.xIdx)
        else
            yLower = unsafe_dot(pfb,  kernel.ϕIdx, x, kernel.xIdx)
            yUpper = unsafe_dot(dpfb, kernel.ϕIdx, x, kernel.xIdx)
        end

        @inbounds buffer[bufIdx] = yLower + yUpper * kernel.α
        update(kernel)
    end

    kernel.inputDeficit = kernel.xIdx - xLen
    self.history        = shiftin!(history, x)

    return bufIdx
end

function Base.filt{Th,Tx}( self::FIRFilter{FIRArbitrary{Th}}, x::Vector{Tx} )
    bufLen         = outputlength(self, length(x))
    buffer         = Array(promote_type(Th,Tx), bufLen)
    samplesWritten = filt!(buffer, self, x)

    samplesWritten == bufLen || resize!( buffer, samplesWritten)

    return buffer
end


#
# Stateless filt implementations
#

# Single-rate, decimation, interpolation, and rational resampling.
function Base.filt(h::Vector, x::Vector, ratio::Rational=1//1)
    self = FIRFilter(h, ratio)
    filt(self, x)
end

# Arbitrary resampling with polyphase interpolation and two neighbor lnear interpolation.
function Base.filt(h::Vector, x::Vector, rate::FloatingPoint, Nϕ::Integer=32)
    self = FIRFilter(h, rate, Nϕ)
    filt(self, x)
end


#
# References
#

# [1] F.J. Harris, *Multirate Signal Processing for Communication Systems*. Prentice Hall, 2004
# [2] Dick, C.; Harris, F., "Options for arbitrary resamplers in FPGA-based modulators," Signals, Systems and Computers, 2004. Conference Record of the Thirty-Eighth Asilomar Conference on , vol.1, no., pp.777,781 Vol.1, 7-10 Nov. 2004
# [3] Kim, S.C.; Plishker, W.L.; Bhattacharyya, S.S., "An efficient GPU implementation of an arbitrary resampling polyphase channelizer," Design and Architectures for Signal and Image Processing (DASIP), 2013 Conference on, vol., no., pp.231,238, 8-10 Oct. 2013
# [4] Horridge, J.P.; Frazer, Gordon J., "Accurate arbitrary resampling with exact delay for radar applications," Radar, 2008 International Conference on , vol., no., pp.123,127, 2-5 Sept. 2008
# [5] Blok, M., "Fractional delay filter design for sample rate conversion," Computer Science and Information Systems (FedCSIS), 2012 Federated Conference on , vol., no., pp.701,706, 9-12 Sept. 2012
