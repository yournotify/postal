# frozen_string_literal: true

class CaddyTrackDomainsController < ApplicationController

  skip_before_action :set_browser_id
  skip_before_action :login_required
  skip_before_action :set_timezone

  def allow
    if TrackDomain.caddy_authorized_for?(params[:domain])
      head :no_content
    else
      head :not_found
    end
  end

end
