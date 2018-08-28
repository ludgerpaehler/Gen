########
# MCMC #
########

function mh(model::Generator, proposal::Generator, proposal_args::Tuple, trace)
    model_args = get_call_record(trace).args
    forward_trace = simulate(proposal, proposal_args, Some(get_choices(trace)))
    forward_score = get_call_record(forward_trace).score
    constraints = get_choices(forward_trace)
    (new_trace, weight, discard) = update(
        model, model_args, NoChange(), trace, constraints)
    backward_trace = assess(proposal, proposal_args, discard, Some(get_choices(new_trace)))
    backward_score = get_call_record(backward_trace).score
    if log(rand()) < weight - forward_score + backward_score
        # accept
        return new_trace
    else
        # reject
        return trace
    end
end

function mh(model::Generator, selector::SelectionFunction, selector_args::Tuple, trace)
    (selection, _) = select(selector, selector_args, get_choices(trace))
    model_args = get_call_record(trace).args
    (new_trace, weight) = regenerate(model, model_args, NoChange(), trace, selection)
    if log(rand()) < weight
        # accept
        return new_trace
    else
        # reject
        return trace
    end
end

export mh

##############################
# Maximum a posteriori (MAP) #
##############################

"""
Backtracking gradient ascent for MAP inference on selected real-valued choices
"""
function map_optimize(model::Generator, selector::SelectionFunction, selector_args::Tuple,
                      trace; max_step_size=0.1, tau=0.5, min_step_size=1e-16, verbose=false)
    model_args = get_call_record(trace).args
    (selection, _) = select(selector, selector_args, get_choices(trace))
    (_, values, gradient) = backprop_trace(model, trace, selection, nothing)
    values_vec = to_array(values, Float64)
    gradient_vec = to_array(gradient, Float64)
    step_size = max_step_size
    score = get_call_record(trace).score
    while true
        new_values_vec = values_vec + gradient_vec * step_size
		(nread, values) = from_array(values, new_values_vec)
		if nread != length(new_values_vec)
        	error("Length mismatch, got array of length $(length(new_values_vec)) but only $nread items read")
		end
        # TODO discard and weight are not actually needed, there should be a more specialized variant
        (new_trace, _, discard, _) = update(model, model_args, NoChange(), trace, values)
        new_score = get_call_record(new_trace).score
        change = new_score - score
        if verbose
            println("step_size: $step_size, prev score: $score, new score: $new_score, change: $change")
        end
        if change >= 0.
            # it got better, return it
            return new_trace
        elseif step_size < min_step_size
            # it got worse, but we ran out of attempts
            return trace
        end
        
        # try again with a smaller step size
        step_size = tau * step_size
    end
end

export map_optimize