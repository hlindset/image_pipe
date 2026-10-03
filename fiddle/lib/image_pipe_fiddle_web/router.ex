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

  @image_mount [instance: ImagePipeFiddle.Images, allow_origin: "*", allow_debug_headers: true]

  forward "/image", ImagePipe.Plug, @image_mount
  forward "/image-signed", ImagePipe.Plug, [url: :signed] ++ @image_mount

  scope "/api", ImagePipeFiddleWeb do
    pipe_through(:api)

    post "/image-path", APIPathController, :create
  end

  scope "/", ImagePipeFiddleWeb do
    pipe_through(:browser)

    get "/*path", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", ImagePipeFiddleWeb do
  #   pipe_through :api
  # end
end
