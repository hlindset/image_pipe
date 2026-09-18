defmodule ImagePipeFiddleWeb.Router do
  use ImagePipeFiddleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ImagePipeFiddleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  forward "/native-image", ImagePipeFiddleWeb.Native
  forward "/img", ImagePipeFiddleWeb.Imgproxy

  scope "/", ImagePipeFiddleWeb do
    pipe_through(:browser)

    get "/*path", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", ImagePipeFiddleWeb do
  #   pipe_through :api
  # end
end
