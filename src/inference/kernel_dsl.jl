import MacroTools

is_primitive(::Function) = false
check_is_kernel(::Function) = false

function check_observations(choices::ChoiceMap, observations::ChoiceMap)
    for (key, value) in get_values_shallow(observations)
        !has_value(choices, key) && error("Check failed: observed choice at $key not found")
        choices[key] != value && error("Check failed: value of observed choice at $key changed")
    end
    for (key, submap) in get_submaps_shallow(observations)
        check_observations(get_submap(choices, key), submap)
    end
end

"""
    @pkern function k(trace, ..)
        ..
        return trace
    end

Declare a Julia function as a primitive stationary kernel.

The first argument of the function should be a trace, and the return value of the function should be a trace.
"""
macro pkern(ex)
    MacroTools.@capture(ex, function f_(args__) body_ end) || error("expected a function")
    escaped_args = map(esc, args)
    quote
        function $(esc(f))($(escaped_args...), check = false, observations = EmptyChoiceMap())
            trace::Trace = $(esc(body))
            check && check_observations(get_choices(trace), observations)
            trace
        end
        Gen.is_primitive(::typeof($(esc(f)))) = true
        Gen.check_is_kernel(::typeof($(esc(f)))) = true
    end
end

function expand_kern_ex(ex)
    MacroTools.@capture(ex, function f_((@T), args__) body_ end) || error("expected kernel syntax: function my_kernel((@T), .) .. end")
    ex = MacroTools.postwalk(MacroTools.unblock, ex)

    trace = gensym("trace")
    ex = MacroTools.postwalk(ex) do x
        if MacroTools.@capture(x, (@T))

            # replace (@T) with trace
            trace
        else
            x
        end
    end

    MacroTools.@capture(ex, function f_(T_, args__) body_ end)
    toplevel_args = args

    body = MacroTools.postwalk(body) do x
        if MacroTools.@capture(x, for idx_ in range_ body_ end)

            # for loops
            quote
                loop_range = $(esc(range))
                for $(esc(idx)) in loop_range
                    $body
                end
                check && (loop_range != $(esc(range))) && error("Check failed in loop")
            end

        elseif MacroTools.@capture(x, if cond_ body_ end)

            # if .. end
            quote
                cond = $(esc(cond))
                if cond
                    $body
                end
                check && (cond != $(esc(cond))) && error("Check failed in if-end")
            end

        elseif MacroTools.@capture(x, let var_ = rhs_; body_ end)

            # let
            quote
                rhs = $(esc(rhs))
                let $(esc(var)) = rhs
                    $body
                end
                check && (rhs != $(esc(rhs))) && error("Check failed in let")
            end

        elseif MacroTools.@capture(x, let idx_ ~ dist_(args__); body_ end)

            # mixture
            quote
                dist = $(esc(dist))
                args = ($(map(esc, args)...),)
                let $(esc(idx)) = dist($(map(esc, args)...))
                    $body
                end
                check && (dist != $(esc(dist))) && error("Check failed in mixture (distribution)")
                check && (args != ($(map(esc, args)...),)) && error("Check failed in mixture (arguments)")
            end

        elseif MacroTools.@capture(x, T_ ~ k_(T_, args__))

            # applying a kernel
            quote
                check && Gen.check_is_kernel($(esc(k)))
                $(esc(trace)) = $(esc(k))($(esc(trace)), $(map(esc, args)...), check)
            end

        else

            # leave it as is
            x
        end
    end

    ex = quote
        function $(esc(f))($(esc(trace))::Trace, $(toplevel_args...), check = false, observations = EmptyChoiceMap())
            $body
            check && check_observations(get_choices($(esc(trace))), observations)
            $(esc(trace))
        end
        Gen.check_is_kernel(::typeof($(esc(f)))) = true
    end

    ex = MacroTools.postwalk(MacroTools.unblock, ex)

    ex, f
end

"""
    k2 = reversal(k1)

Return the reversal kernel for a given kernel.
"""
function reversal(f)
    check_is_kernel(f)
    error("Reversal for kernel $f is not defined")
end

"""
    @rkern k1 : k2

Declare that two primitive stationary kernels are reversals of one another.

The two kernels must have the same argument type signatures.
"""
macro rkern(ex)
    MacroTools.@capture(ex, k_ : l_) || error("expected a pair of functions")
    quote
        Gen.is_primitive($(esc(k))) || error("first function is not a primitive kernel")
        Gen.is_primitive($(esc(l))) || error("second function is not a primitive kernel")
        Gen.reversal(::typeof($(esc(k)))) = $(esc(l))
        Gen.reversal(::typeof($(esc(l)))) = $(esc(k))
    end
end


function reversal_ex(ex)

    ex = MacroTools.postwalk(MacroTools.unblock, ex)
    MacroTools.@capture(ex, function f_(args__) body_ end) || error("expected a function")
    toplevel_args = args

    # modify the body
    body = MacroTools.postwalk(body) do x
        x = if MacroTools.@capture(x, for idx_ in range_ body_ end)

            # for loops - reverse the order of loop indices
            quote
                for $idx in reverse($range)
                    $body
                end
            end

        elseif MacroTools.@capture(x, (@T) ~ k_((@T), args__))

            # applying a kernel - apply the reverse kernel
            quote
                (@T) ~ (Gen.reversal($k))((@T), $(args...))
            end

        elseif isa(x, Expr) && x.head == :block

            # a sequence of things -- reverse the order
            Expr(:block, reverse(x.args)...)

        else

            # leave it as is
            x
        end
    end

    # change the name
    rev = gensym("reverse_kernel")
    ex = quote
        function $rev($(toplevel_args...))
            $body
        end
    end

    ex = MacroTools.postwalk(MacroTools.unblock, ex)
end

"""
    @ckern function k((@T), ..)
        ..
    end

Construct a composite MCMC kernel.

The resulting object is a Julia function that is annotated as a composite MCMC kernel, and can be called as a Julia function or applied within other composite kernels.
"""
macro ckern(ex)
    kern_ex, kern = expand_kern_ex(ex)
    rev_kern_ex, rev_kern = expand_kern_ex(reversal_ex(ex))
    quote
        # define forward kerel
        $kern_ex
        
        # define reversal kernel
        $rev_kern_ex

        # bind the reversals for both
        Gen.reversal(::typeof($(esc(kern)))) = $(esc(rev_kern))
        Gen.reversal(::typeof($(esc(rev_kern)))) = $(esc(kern))
    end
end

export @pkern, @rkern, @ckern, reversal
