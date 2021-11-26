class ApplicationController < ActionController::Base
  rescue_from ActiveRecord::RecordNotFound, with: :not_found

  rescue_from ActiveRecord::RecordInvalid do |exception|
    render_model_errors exception.record
  end

  rescue_from ActiveRecord::StatementInvalid,
              ActiveRecord::RecordNotUnique,
              ActiveRecord::RecordNotDestroyed do |exception|
    render_error exception.message
  end

  private

  def base_create_action(attributes: nil, render_type: nil)
    attributes ||= action_params
    record = model_class.new(attributes)

    record.save ? render_model(record, type: render_type, status: 201) : render_model_errors(record)
  end

  def base_update_action(render_type: nil)
    record = find_record

    record.update(action_params) ? render_model(record, type: render_type) : render_model_errors(record)
  end

  def base_destroy_action
    record = find_record

    record.destroy ? render_message('destroyed') : render_model_errors(record)
  end

  def base_index_action
    collection = model_class.query(**action_params)
    render_model collection, type: params[:type]&.to_sym
  end

  def base_show_action
    record = find_record
    render_model record, type: params[:type]&.to_sym || :full
  end

  def perform(operation_class, input: operation_input, presenter_class: nil, type: nil, &on_success)
    operation_class.new.(**input).either(
      on_success ||
        -> value {
          case value
          in String
            render_message value
          in Hash | Array if presenter_class.nil?
            render_json value
          else
            render_model value, presenter_class: presenter_class, type: type
          end
        },
      -> value {
        case value
        in String
          render_error value
        else
          render_model_errors value
        end
      }
    )
  end

  def _perform(operation_class, input: operation_input, success: :render_model, failure: :render_model_errors)
    success = method(success) unless success.respond_to?(:call)
    failure = method(failure) unless failure.respond_to?(:call)

    operation_class.new.(**input).either(success, failure)
  end

  def perform_async(operation_class, input: action_params)
    OperationJob.perform_later(operation_class.name, input)
    render_message 'Operation queued.'
  end

  def action_params
    params.except(:controller, :action, :format, :type).to_unsafe_hash.deep_symbolize_keys
  end

  def operation_input
    input = action_params
    id = input.delete(:id)
    return input unless id

    input = {params: input} unless input.empty?
    model = find_record
    input.store model.model_name.element.to_sym, model
    input
  end

  def model_class
    return @model_class if defined? @model_class

    @model_class = controller_name.classify.safe_constantize
  end

  def find_record(scope = model_class)
    scope.find(params[:id])
  end

  def render_model(model, presenter_class: nil, type: nil, status: 200)
    render_json present_model(model, presenter_class: presenter_class, type: type), status
  end

  def present_model(model, presenter_class: nil, type: nil)
    if presenter_class.nil?
      class_name = model_class&.name || model.respond_to?(:model_name) ?
                     model.model_name.name :
                     (model.respond_to?(:first) ? model.first : model).class.name
      presenter_class = "#{class_name}Entity".safe_constantize
    end

    presenter_class.represent model, type: type
  end

  def render_json(json, status = 200)
    render json: json, status: status
  end

  def render_model_errors(record)
    render_error record.errors.full_messages.to_sentence
  end

  def render_message(message, status = 200)
    render_json({message: message}, status)
  end

  def render_error(error, status = 400)
    render_json({error: error}, status)
  end

  def not_found(exception)
    render_error exception.message, 404
  end
end
