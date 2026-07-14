module JobTests exposing (all)

import Application.Application as Application
import Assets
import Common exposing (defineHoverBehaviour, expectTooltip, hoverOver, queryView)
import Concourse exposing (Build, JsonValue(..))
import Concourse.BuildStatus exposing (BuildStatus(..))
import Concourse.Pagination exposing (Direction(..), Paginated)
import DashboardTests exposing (darkGrey, iconSelector, middleGrey)
import Data
import Dict
import Expect exposing (..)
import Html.Attributes as Attr
import Http
import Job.Job as Job exposing (update)
import Message.Callback as Callback exposing (Callback(..))
import Message.Effects as Effects
import Message.Message exposing (DomID(..), Message(..))
import Message.Subscription as Subscription
    exposing
        ( Delivery(..)
        , Interval(..)
        )
import Message.TopLevelMessage as Msgs
import RemoteData
import Routes
import Test exposing (..)
import Test.Html.Event as Event
import Test.Html.Query as Query
import Test.Html.Selector as Selector
    exposing
        ( attribute
        , class
        , containing
        , id
        , style
        , text
        )
import Time
import Url
import Views.Styles


all : Test
all =
    describe "Job"
        [ describe "update" <|
            [ describe "while page is loading"
                [ test "title includes job name" <|
                    \_ ->
                        Common.init "/teams/team/pipelines/pipeline/jobs/job"
                            |> Application.view
                            |> .title
                            |> Expect.equal "job - Concourse"
                , test "gets current timezone" <|
                    \_ ->
                        Application.init Data.flags
                            { protocol = Url.Http
                            , host = ""
                            , port_ = Nothing
                            , path = "/teams/team/pipelines/pipeline/jobs/job"
                            , query = Nothing
                            , fragment = Nothing
                            }
                            |> Tuple.second
                            |> Common.contains Effects.GetCurrentTimeZone
                , test "fetches pipelines" <|
                    \_ ->
                        Application.init Data.flags
                            { protocol = Url.Http
                            , host = ""
                            , port_ = Nothing
                            , path = "/teams/team/pipelines/pipeline/jobs/job"
                            , query = Nothing
                            , fragment = Nothing
                            }
                            |> Tuple.second
                            |> Common.contains Effects.FetchAllPipelines
                , test "shows two spinners before anything has loaded" <|
                    \_ ->
                        Common.init "/teams/team/pipelines/pipeline/jobs/job"
                            |> queryView
                            |> Query.findAll loadingIndicatorSelector
                            |> Query.count (Expect.equal 2)
                , test "loading build has spinners for inputs and outputs" <|
                    init { disabled = False, paused = False }
                        >> Application.handleCallback
                            (JobBuildsFetched <|
                                Ok ( Job.startingPage, buildsWithEmptyPagination )
                            )
                        >> Tuple.first
                        >> queryView
                        >> Expect.all
                            [ Query.find [ class "inputs" ]
                                >> Query.has loadingIndicatorSelector
                            , Query.find [ class "outputs" ]
                                >> Query.has loadingIndicatorSelector
                            ]
                ]
            , test "build header lays out contents horizontally" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ class "build-header" ]
                    >> Query.has
                        [ style "display" "flex"
                        , style "justify-content" "space-between"
                        ]
            , test "header has play/pause button at the left" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ class "build-header" ]
                    >> Query.has [ id toggleJobID ]
            , test "play/pause has background of the header color, faded" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ id toggleJobID ]
                    >> Query.has
                        [ style "padding" "10px"
                        , style "border" "none"
                        , style "background-color" darkGreen
                        , style "outline" "none"
                        ]
            , test "hover play/pause has background of the header color" <|
                init { disabled = False, paused = False }
                    >> Application.update
                        (Msgs.Update <|
                            Message.Message.Hover <|
                                Just Message.Message.ToggleJobButton
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find [ id toggleJobID ]
                    >> Query.has
                        [ style "padding" "10px"
                        , style "border" "none"
                        , style "background-color" brightGreen
                        , style "outline" "none"
                        ]
            , defineHoverBehaviour
                { name = "play/pause button when job is unpaused"
                , setup =
                    init { disabled = False, paused = False } ()
                , query =
                    queryView >> Query.find [ id toggleJobID ]
                , unhoveredSelector =
                    { description = "grey pause icon"
                    , selector =
                        [ style "opacity" "0.5" ]
                            ++ iconSelector
                                { size = "40px"
                                , image = Assets.PauseCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoveredSelector =
                    { description = "white pause icon"
                    , selector =
                        [ style "opacity" "1" ]
                            ++ iconSelector
                                { size = "40px"
                                , image = Assets.PauseCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoverable = Message.Message.ToggleJobButton
                }
            , defineHoverBehaviour
                { name = "play/pause button when job is paused"
                , setup =
                    init { disabled = False, paused = True } ()
                , query =
                    queryView >> Query.find [ id toggleJobID ]
                , unhoveredSelector =
                    { description = "grey play icon"
                    , selector =
                        [ style "opacity" "0.5" ]
                            ++ iconSelector
                                { size = "40px"
                                , image = Assets.PlayCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoveredSelector =
                    { description = "white play icon"
                    , selector =
                        [ style "opacity" "1" ]
                            ++ iconSelector
                                { size = "40px"
                                , image = Assets.PlayCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoverable = Message.Message.ToggleJobButton
                }
            , test "trigger build button has background of the header color, faded" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find
                        [ attribute <|
                            Attr.attribute "aria-label" "Trigger Build"
                        ]
                    >> Query.has
                        [ style "padding" "10px"
                        , style "border" "none"
                        , style "background-color" darkGreen
                        , style "outline" "none"
                        ]
            , test "hovered trigger build button has background of the header color" <|
                init { disabled = False, paused = False }
                    >> Application.update
                        (Msgs.Update <|
                            Message.Message.Hover <|
                                Just Message.Message.TriggerBuildButton
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find
                        [ attribute <|
                            Attr.attribute "aria-label" "Trigger Build"
                        ]
                    >> Query.has
                        [ style "padding" "10px"
                        , style "border" "none"
                        , style "background-color" brightGreen
                        , style "outline" "none"
                        ]
            , test "trigger build button has 'plus' icon" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find
                        [ attribute <|
                            Attr.attribute "aria-label" "Trigger Build"
                        ]
                    >> Query.children []
                    >> Query.first
                    >> Query.has
                        (iconSelector
                            { size = "40px"
                            , image = Assets.AddCircleIcon |> Assets.CircleOutlineIcon
                            }
                        )
            , defineHoverBehaviour
                { name = "trigger build button"
                , setup =
                    init { disabled = False, paused = False } ()
                , query =
                    queryView
                        >> Query.find
                            [ attribute <|
                                Attr.attribute "aria-label" "Trigger Build"
                            ]
                , unhoveredSelector =
                    { description = "grey plus icon"
                    , selector =
                        [ style "opacity" "0.5" ]
                            ++ iconSelector
                                { size = "40px"
                                , image = Assets.AddCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoveredSelector =
                    { description = "white plus icon"
                    , selector =
                        [ style "opacity" "1" ]
                            ++ iconSelector
                                { size = "40px"
                                , image = Assets.AddCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoverable = Message.Message.TriggerBuildButton
                }
            , defineHoverBehaviour
                { name = "disabled trigger build button"
                , setup =
                    init { disabled = True, paused = False } ()
                , query =
                    queryView
                        >> Query.find
                            [ attribute <|
                                Attr.attribute "aria-label" "Trigger Build"
                            ]
                , unhoveredSelector =
                    { description = "grey plus icon"
                    , selector =
                        [ style "opacity" "0.5" ]
                            ++ iconSelector
                                { size = "40px"
                                , image = Assets.AddCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoveredSelector =
                    { description = "grey plus icon"
                    , selector =
                        style "opacity" "0.5"
                            :: iconSelector
                                { size = "40px"
                                , image = Assets.AddCircleIcon |> Assets.CircleOutlineIcon
                                }
                    }
                , hoverable = Message.Message.TriggerBuildButton
                }
            , test "hovering trigger build button has tooltip" <|
                init { disabled = False, paused = False }
                    >> expectTooltip TriggerBuildButton "trigger a new build"
            , test "hovering disabled trigger build button has tooltip" <|
                init { disabled = True, paused = False }
                    >> expectTooltip TriggerBuildButton "manual triggering disabled in job config"
            , test "hovering pause toggle button has tooltip" <|
                init { disabled = False, paused = False }
                    >> expectTooltip ToggleJobButton "pause job"
            , test "hovering paused pause toggle button has tooltip" <|
                init { disabled = False, paused = True }
                    >> expectTooltip ToggleJobButton "unpause job"
            , test "hovering build link has tooltip" <|
                init { disabled = False, paused = True }
                    >> expectTooltip (JobBuildLink "1.1") "view build #1.1"
            , test "hovering next page button has tooltip" <|
                init { disabled = False, paused = True }
                    >> expectTooltip NextPageButton "view next page"
            , test "hovering previous page button has tooltip" <|
                init { disabled = False, paused = True }
                    >> expectTooltip PreviousPageButton "view previous page"
            , describe "archived pipelines" <|
                let
                    fetchArchivedPipeline =
                        Application.handleCallback
                            (Callback.AllPipelinesFetched <|
                                Ok
                                    [ Data.pipeline "team" 0
                                        |> Data.withName "pipeline"
                                        |> Data.withArchived True
                                    , Data.pipeline "team" 1
                                        |> Data.withName "pipeline"
                                        |> Data.withInstanceVars (Dict.fromList [ ( "foo", JsonNumber 1 ) ])
                                        |> Data.withArchived False
                                    ]
                            )
                            >> Tuple.first

                    initWithArchivedPipeline =
                        init { paused = False, disabled = False } >> fetchArchivedPipeline
                in
                [ test "play/pause button not displayed" <|
                    initWithArchivedPipeline
                        >> queryView
                        >> Query.find [ class "build-header" ]
                        >> Query.hasNot [ id toggleJobID ]
                , test "header still includes job name" <|
                    initWithArchivedPipeline
                        >> queryView
                        >> Query.find [ class "build-header" ]
                        >> Query.has [ text "job" ]
                , test "trigger build button not displayed" <|
                    initWithArchivedPipeline
                        >> queryView
                        >> Query.find [ class "build-header" ]
                        >> Query.hasNot [ class "trigger-build" ]
                , test "pipeline lookup considers instance vars" <|
                    let
                        job =
                            Data.job 1
                                |> Data.withPipelineInstanceVars (Dict.fromList [ ( "foo", JsonNumber 1 ) ])
                    in
                    \_ ->
                        Common.initRoute (Routes.jobRoute job)
                            |> Application.handleCallback (JobFetched <| Ok job)
                            |> Tuple.first
                            |> fetchArchivedPipeline
                            |> queryView
                            |> Query.find [ class "build-header" ]
                            |> Query.has [ class "trigger-build" ]
                ]
            , test "page below top bar fills height without scrolling" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ id "page-below-top-bar" ]
                    >> Query.has
                        [ style "box-sizing" "border-box"
                        , style "height" "100%"
                        , style "display" "flex"
                        ]
            , test "page contents fill available space and align vertically" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ id "page-below-top-bar" ]
                    >> Query.has
                        [ style "flex-grow" "1"
                        , style "display" "flex"
                        , style "flex-direction" "column"
                        ]
            , test "body scrolls independently" <|
                init { disabled = False, paused = False }
                    >> Application.handleCallback
                        (JobBuildsFetched <|
                            Ok ( Job.startingPage, buildsWithEmptyPagination )
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find [ class "job-body" ]
                    >> Query.has [ style "overflow-y" "auto" ]
            , test "inputs icon on build" <|
                init { disabled = False, paused = False }
                    >> Application.handleCallback
                        (JobBuildsFetched <|
                            Ok ( Job.startingPage, buildsWithEmptyPagination )
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find [ class "inputs" ]
                    >> Query.children []
                    >> Query.first
                    >> Expect.all
                        [ Query.has
                            [ style "display" "flex"
                            , style "align-items" "center"
                            , style "padding-bottom" "5px"
                            ]
                        , Query.children []
                            >> Query.first
                            >> Query.has
                                (iconSelector
                                    { size = "12px"
                                    , image = Assets.DownArrow
                                    }
                                    ++ [ style "background-size" "contain"
                                       , style "margin-right" "5px"
                                       ]
                                )
                        ]
            , test "outputs icon on build" <|
                init { disabled = False, paused = False }
                    >> Application.handleCallback
                        (JobBuildsFetched <|
                            Ok ( Job.startingPage, buildsWithEmptyPagination )
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find [ class "outputs" ]
                    >> Query.children []
                    >> Query.first
                    >> Expect.all
                        [ Query.has
                            [ style "display" "flex"
                            , style "align-items" "center"
                            , style "padding-bottom" "5px"
                            ]
                        , Query.children []
                            >> Query.first
                            >> Query.has
                                (iconSelector
                                    { size = "12px"
                                    , image = Assets.UpArrow
                                    }
                                    ++ [ style "background-size" "contain"
                                       , style "margin-right" "5px"
                                       ]
                                )
                        ]
            , test "pagination header lays out horizontally" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ id "pagination-header" ]
                    >> Query.has
                        [ style "display" "flex"
                        , style "justify-content" "space-between"
                        , style "align-items" "stretch"
                        , style "background-color" darkGrey
                        , style "height" "60px"
                        ]
            , test "the word 'builds' is indented" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ id "pagination-header" ]
                    >> Query.children []
                    >> Query.first
                    >> Query.has
                        [ containing [ text "builds" ]
                        , style "margin" "0 18px"
                        ]
            , test "pagination lays out horizontally" <|
                init { disabled = False, paused = False }
                    >> queryView
                    >> Query.find [ id "pagination" ]
                    >> Query.has
                        [ style "display" "flex"
                        , style "align-items" "stretch"
                        ]
            , test "pagination chevrons with no pages" <|
                init { disabled = False, paused = False }
                    >> Application.handleCallback
                        (JobBuildsFetched <|
                            Ok ( Job.startingPage, buildsWithEmptyPagination )
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find [ id "pagination" ]
                    >> Query.children []
                    >> Expect.all
                        [ Query.index 0
                            >> Query.has
                                [ style "padding" "5px"
                                , style "display" "flex"
                                , style "align-items" "center"
                                , style "border-left" <|
                                    "1px solid "
                                        ++ middleGrey
                                , containing
                                    (iconSelector
                                        { image = Assets.ChevronLeft
                                        , size = "24px"
                                        }
                                        ++ [ style "padding" "5px"
                                           , style "opacity" "0.5"
                                           ]
                                    )
                                ]
                        , Query.index 1
                            >> Query.has
                                [ style "padding" "5px"
                                , style "display" "flex"
                                , style "align-items" "center"
                                , style "border-left" <|
                                    "1px solid "
                                        ++ middleGrey
                                , containing
                                    (iconSelector
                                        { image = Assets.ChevronRight
                                        , size = "24px"
                                        }
                                        ++ [ style "padding" "5px"
                                           , style "opacity" "0.5"
                                           ]
                                    )
                                ]
                        ]
            , defineHoverBehaviour <|
                let
                    urlPath =
                        "/teams/team/pipelines/pipeline/jobs/job?from=1&limit=1"
                in
                { name = "left pagination chevron with previous page"
                , setup =
                    let
                        prevPage =
                            { direction = From 1
                            , limit = 1
                            }
                    in
                    init { disabled = False, paused = False } ()
                        |> Application.handleCallback
                            (JobBuildsFetched <|
                                Ok
                                    ( Job.startingPage
                                    , { pagination =
                                            { previousPage = Just prevPage
                                            , nextPage = Nothing
                                            }
                                      , content = builds
                                      }
                                    )
                            )
                        |> Tuple.first
                , query =
                    queryView
                        >> Query.find [ id "pagination" ]
                        >> Query.children []
                        >> Query.index 0
                , unhoveredSelector =
                    { description = "white left chevron"
                    , selector =
                        [ style "padding" "5px"
                        , style "display" "flex"
                        , style "align-items" "center"
                        , style "border-left" <|
                            "1px solid "
                                ++ middleGrey
                        , containing
                            (iconSelector
                                { image = Assets.ChevronLeft
                                , size = "24px"
                                }
                                ++ [ style "padding" "5px"
                                   , style "opacity" "1"
                                   , attribute <| Attr.href urlPath
                                   ]
                            )
                        ]
                    }
                , hoveredSelector =
                    { description =
                        "left chevron with light grey circular bg"
                    , selector =
                        [ style "padding" "5px"
                        , style "display" "flex"
                        , style "align-items" "center"
                        , style "border-left" <|
                            "1px solid "
                                ++ middleGrey
                        , containing
                            (iconSelector
                                { image = Assets.ChevronLeft
                                , size = "24px"
                                }
                                ++ [ style "padding" "5px"
                                   , style "opacity" "1"
                                   , style "border-radius" "50%"
                                   , style "background-color" <|
                                        "#504b4b"
                                   , attribute <| Attr.href urlPath
                                   ]
                            )
                        ]
                    }
                , hoverable = Message.Message.PreviousPageButton
                }
            , test "pagination previous page loads most recent page if less than 100 entries" <|
                \_ ->
                    let
                        previousPage =
                            { direction = From 1, limit = 100 }
                    in
                    init { disabled = False, paused = False } ()
                        |> Application.handleCallback
                            (JobBuildsFetched <|
                                Ok
                                    ( previousPage
                                    , { pagination =
                                            { previousPage = Nothing
                                            , nextPage = Nothing
                                            }
                                      , content = []
                                      }
                                    )
                            )
                        |> Tuple.second
                        |> Common.contains
                            (Effects.FetchJobBuilds Data.jobId Job.startingPage)
            , describe "When fetching builds"
                [ test "says no builds" <|
                    \_ ->
                        init { disabled = False, paused = False } ()
                            |> Application.handleCallback
                                (JobBuildsFetched <|
                                    Ok
                                        ( Job.startingPage
                                        , { pagination =
                                                { previousPage = Nothing
                                                , nextPage = Nothing
                                                }
                                          , content = []
                                          }
                                        )
                                )
                            |> Tuple.first
                            |> queryView
                            |> Query.has [ text "no builds for job \"job\"" ]
                ]
            , test "JobBuildsFetched" <|
                \_ ->
                    Expect.equal
                        { defaultModel
                            | currentPage =
                                { direction = Concourse.Pagination.To 123
                                , limit = 1
                                }
                            , buildsWithResources =
                                RemoteData.Success
                                    { content =
                                        [ { build = someBuild
                                          , resources = Nothing
                                          }
                                        ]
                                    , pagination =
                                        { previousPage = Nothing
                                        , nextPage = Nothing
                                        }
                                    }
                        }
                    <|
                        Tuple.first <|
                            Job.handleCallback
                                (JobBuildsFetched <|
                                    Ok
                                        ( Job.startingPage
                                        , { content = [ someBuild ]
                                          , pagination =
                                                { previousPage = Nothing
                                                , nextPage = Nothing
                                                }
                                          }
                                        )
                                )
                                ( defaultModel, [] )
            , test "JobBuildsFetched error" <|
                \_ ->
                    Expect.equal
                        defaultModel
                    <|
                        Tuple.first <|
                            Job.handleCallback
                                (JobBuildsFetched <| Err Http.NetworkError)
                                ( defaultModel, [] )
            , test "JobFetched" <|
                \_ ->
                    Expect.equal
                        { defaultModel
                            | job = RemoteData.Success someJob
                        }
                    <|
                        Tuple.first <|
                            Job.handleCallback (JobFetched <| Ok someJob) ( defaultModel, [] )
            , test "JobFetched error" <|
                \_ ->
                    Expect.equal
                        defaultModel
                    <|
                        Tuple.first <|
                            Job.handleCallback
                                (JobFetched <| Err Http.NetworkError)
                                ( defaultModel, [] )
            , test "BuildResourcesFetched" <|
                \_ ->
                    let
                        buildInput =
                            { name = "some-input"
                            , version = Dict.fromList [ ( "version", "v1" ) ]
                            , firstOccurrence = True
                            }

                        buildOutput =
                            { name = "some-resource"
                            , version = Dict.fromList [ ( "version", "v2" ) ]
                            }
                    in
                    let
                        buildResources =
                            { inputs = [ buildInput ]
                            , outputs = [ buildOutput ]
                            }
                    in
                    Expect.equal
                        defaultModel
                    <|
                        Tuple.first <|
                            Job.handleCallback (BuildResourcesFetched (Ok ( 1, buildResources )))
                                ( defaultModel, [] )
            , test "BuildResourcesFetched error" <|
                \_ ->
                    Expect.equal
                        defaultModel
                    <|
                        Tuple.first <|
                            Job.handleCallback
                                (BuildResourcesFetched (Err Http.NetworkError))
                                ( defaultModel, [] )
            , test "TogglePaused" <|
                \_ ->
                    Expect.equal
                        { defaultModel
                            | job = RemoteData.Success { someJob | paused = True }
                            , pausedChanging = True
                        }
                    <|
                        Tuple.first <|
                            update
                                (Click ToggleJobButton)
                                ( { defaultModel | job = RemoteData.Success someJob }, [] )
            , test "PausedToggled" <|
                \_ ->
                    Expect.equal
                        { defaultModel
                            | job = RemoteData.Success someJob
                            , pausedChanging = False
                        }
                    <|
                        Tuple.first <|
                            Job.handleCallback
                                (PausedToggled <| Ok ())
                                ( { defaultModel | job = RemoteData.Success someJob }, [] )
            , test "PausedToggled error" <|
                \_ ->
                    Expect.equal
                        { defaultModel | job = RemoteData.Success someJob }
                    <|
                        Tuple.first <|
                            Job.handleCallback
                                (PausedToggled <| Err Http.NetworkError)
                                ( { defaultModel | job = RemoteData.Success someJob }, [] )
            , test "PausedToggled unauthorized" <|
                \_ ->
                    Expect.equal
                        { defaultModel | job = RemoteData.Success someJob }
                    <|
                        Tuple.first <|
                            Job.handleCallback (PausedToggled <| Data.httpUnauthorized)
                                ( { defaultModel | job = RemoteData.Success someJob }, [] )
            , test "page is subscribed to one and five second timers" <|
                init { disabled = False, paused = False }
                    >> Application.subscriptions
                    >> Expect.all
                        [ Common.contains (Subscription.OnClockTick OneSecond)
                        , Common.contains (Subscription.OnClockTick FiveSeconds)
                        ]
            , test "on five-second timer, refreshes job and builds" <|
                init { disabled = False, paused = False }
                    >> Application.update
                        (Msgs.DeliveryReceived <|
                            ClockTicked FiveSeconds <|
                                Time.millisToPosix 0
                        )
                    >> Tuple.second
                    >> Expect.all
                        [ Common.contains (Effects.FetchJobBuilds jobInfo { direction = ToMostRecent, limit = 100 })
                        , Common.contains (Effects.FetchJob jobInfo)
                        ]
            , test "on one-second timer, updates build timestamps" <|
                init { disabled = False, paused = False }
                    >> Application.handleCallback
                        (Callback.JobBuildsFetched <|
                            Ok
                                ( Job.startingPage
                                , { content = [ someBuild ]
                                  , pagination =
                                        { nextPage = Nothing
                                        , previousPage = Nothing
                                        }
                                  }
                                )
                        )
                    >> Tuple.first
                    >> Application.update
                        (Msgs.DeliveryReceived <|
                            ClockTicked OneSecond <|
                                Time.millisToPosix (2 * 1000)
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find [ class "js-build" ]
                    >> Query.has [ text "2s ago" ]
            , test "shows build timestamps in current timezone" <|
                init { disabled = False, paused = False }
                    >> Application.handleCallback
                        (Callback.GotCurrentTimeZone <|
                            Time.customZone (5 * 60) []
                        )
                    >> Tuple.first
                    >> Application.handleCallback
                        (Callback.JobBuildsFetched <|
                            Ok
                                ( Job.startingPage
                                , { content = [ someBuild ]
                                  , pagination =
                                        { nextPage = Nothing
                                        , previousPage = Nothing
                                        }
                                  }
                                )
                        )
                    >> Tuple.first
                    >> Application.update
                        (Msgs.DeliveryReceived <|
                            ClockTicked OneSecond <|
                                Time.millisToPosix (24 * 60 * 60 * 1000)
                        )
                    >> Tuple.first
                    >> queryView
                    >> Query.find [ class "js-build" ]
                    >> Query.has [ text "Jan 1 1970 05:00:00 AM" ]
            , describe "trigger build vars form"
                [ test "clicking trigger button triggers build immediately when job has no vars" <|
                    init { disabled = False, paused = False }
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.second
                        >> Common.contains (Effects.DoTriggerBuild jobInfo)
                , test "no form is shown when job has no vars" <|
                    init { disabled = False, paused = False }
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.hasNot [ id "trigger-build-form" ]
                , test "clicking trigger button shows the form when job has vars" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.has [ id "trigger-build-form" ]
                , test "clicking trigger button does not trigger a build when job has vars" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.second
                        >> Common.notContains (Effects.DoTriggerBuild jobInfo)
                , test "form is hidden before the trigger button is clicked" <|
                    initWithVars
                        >> queryView
                        >> Query.hasNot [ id "trigger-build-form" ]
                , test "form inputs are pre-filled with defaults rendered as text" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.find [ id "trigger-build-form" ]
                        >> Expect.all
                            [ Query.find [ id "trigger-build-form-var-branch" ]
                                >> Query.has [ attribute <| Attr.value "main" ]
                            , Query.find [ id "trigger-build-form-var-count" ]
                                >> Query.has [ attribute <| Attr.value "1" ]
                            , Query.find [ id "trigger-build-form-var-confirm_release" ]
                                >> Query.children []
                                >> Query.index 0
                                >> Query.has [ attribute <| Attr.selected True, text "-- select --" ]
                            , Query.find [ id "trigger-build-form-var-deploy_env" ]
                                >> Query.children []
                                >> Query.index 0
                                >> Query.has [ attribute <| Attr.selected True, text "dev" ]
                            ]
                , test "form shows var names, descriptions and required markers" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.find [ id "trigger-build-form" ]
                        >> Expect.all
                            [ Query.has [ text "branch" ]
                            , Query.has [ text "branch to build" ]
                            , Query.has [ text "confirm_release (required)" ]
                            , Query.has [ text "skip cloning" ]
                            , Query.has [ text "environment (required)" ]
                            , Query.has [ text "Trigger values are stored with build metadata. Do not enter secrets." ]
                            ]
                , test "typing in a var field sends TriggerBuildVarChanged" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.find [ id "trigger-build-form-var-branch" ]
                        >> Event.simulate (Event.input "feature")
                        >> Event.expect
                            (Msgs.Update <| TriggerBuildVarChanged "branch" "feature")
                , test "toggling a boolean field sends TriggerBuildVarChanged" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.find [ id "trigger-build-form-var-dry_run" ]
                        >> Event.simulate (Event.check True)
                        >> Event.expect
                            (Msgs.Update <| TriggerBuildVarChanged "dry_run" "true")
                , test "selecting false for a required boolean sends TriggerBuildVarChanged" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.find [ id "trigger-build-form-var-confirm_release" ]
                        >> Event.simulate (Event.input "false")
                        >> Event.expect
                            (Msgs.Update <| TriggerBuildVarChanged "confirm_release" "false")
                , test "submitting the form triggers a build with only the edited vars" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| TriggerBuildVarChanged "branch" "feature")
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| TriggerBuildVarChanged "confirm_release" "false")
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormSubmitButton)
                        >> Tuple.second
                        >> Common.contains
                            (Effects.DoTriggerBuildWithVars jobInfo
                                (Dict.fromList
                                    [ ( "branch", JsonString "feature" )
                                    , ( "confirm_release", JsonBoolean False )
                                    ]
                                )
                            )
                , test "submitting typed fields preserves their types" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update (Msgs.Update <| TriggerBuildVarChanged "count" "3")
                        >> Tuple.first
                        >> Application.update (Msgs.Update <| TriggerBuildVarChanged "dry_run" "true")
                        >> Tuple.first
                        >> Application.update (Msgs.Update <| TriggerBuildVarChanged "confirm_release" "false")
                        >> Tuple.first
                        >> Application.update (Msgs.Update <| TriggerBuildVarChanged "deploy_env" "prod")
                        >> Tuple.first
                        >> Application.update (Msgs.Update <| Click TriggerBuildFormSubmitButton)
                        >> Tuple.second
                        >> Common.contains
                            (Effects.DoTriggerBuildWithVars jobInfo
                                (Dict.fromList
                                    [ ( "count", JsonNumber 3 )
                                    , ( "confirm_release", JsonBoolean False )
                                    , ( "dry_run", JsonBoolean True )
                                    , ( "deploy_env", JsonString "prod" )
                                    ]
                                )
                            )
                , test "submitting the form keeps it open until the trigger succeeds" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormSubmitButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.has [ id "trigger-build-form" ]
                , test "the form hides once the trigger succeeds" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormSubmitButton)
                        >> Tuple.first
                        >> Application.handleCallback
                            (BuildTriggered <| Ok someBuild)
                        >> Tuple.first
                        >> queryView
                        >> Query.hasNot [ id "trigger-build-form" ]
                , test "a rejected trigger shows the server's error in the form" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormSubmitButton)
                        >> Tuple.first
                        >> Application.handleCallback
                            (BuildTriggered Data.httpBadRequest)
                        >> Tuple.first
                        >> queryView
                        >> Query.find [ id "trigger-build-form-error" ]
                        >> Query.has
                            [ Selector.text "failed to trigger: undeclared var(s): nope" ]
                , test "cleared typed fields are omitted from the submitted vars" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| TriggerBuildVarChanged "count" "")
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormSubmitButton)
                        >> Tuple.second
                        >> Common.contains
                            (Effects.DoTriggerBuildWithVars jobInfo Dict.empty)
                , test "a string var cleared to empty submits an empty string" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| TriggerBuildVarChanged "branch" "")
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormSubmitButton)
                        >> Tuple.second
                        >> Common.contains
                            (Effects.DoTriggerBuildWithVars jobInfo
                                (Dict.fromList [ ( "branch", JsonString "" ) ])
                            )
                , test "clicking cancel hides the form" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormCancelButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.hasNot [ id "trigger-build-form" ]
                , test "clicking the trigger button again hides the form" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.hasNot [ id "trigger-build-form" ]
                , test "edited values are cleared when the form is cancelled" <|
                    initWithVars
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| TriggerBuildVarChanged "branch" "feature")
                        >> Tuple.first
                        >> Application.update
                            (Msgs.Update <| Click TriggerBuildFormCancelButton)
                        >> Tuple.first
                        >> Application.update (Msgs.Update <| Click TriggerBuildButton)
                        >> Tuple.first
                        >> queryView
                        >> Query.find [ id "trigger-build-form-var-branch" ]
                        >> Query.has [ attribute <| Attr.value "main" ]
                ]
            ]
        ]


darkGreen : String
darkGreen =
    "#0D9448"


brightGreen : String
brightGreen =
    "#1CBD63"


someJobInfo : Concourse.JobIdentifier
someJobInfo =
    Data.jobId |> Data.withJobName "some-job"


someBuild : Build
someBuild =
    Data.jobBuild BuildStatusSucceeded
        |> Data.withId 123
        |> Data.withName "45"
        |> Data.withJob (Just someJobInfo)
        |> Data.withReapTime (Just <| Time.millisToPosix 0)


jobInfo : Concourse.JobIdentifier
jobInfo =
    Data.jobId


builds : List Build
builds =
    [ Data.jobBuild BuildStatusSucceeded
        |> Data.withId 0
        |> Data.withName "0"
        |> Data.withJob (Just jobInfo)
        |> Data.withDuration
            { startedAt = Nothing
            , finishedAt = Nothing
            }
    ]


buildsWithEmptyPagination : Paginated Build
buildsWithEmptyPagination =
    { content = builds
    , pagination =
        { previousPage = Nothing
        , nextPage = Nothing
        }
    }


someJob : Concourse.Job
someJob =
    Data.job 1
        |> Data.withName "some-job"
        |> Data.withPipelineName "some-pipeline"
        |> Data.withTeamName "some-team"
        |> Data.withFinishedBuild (Just someBuild)


defaultModel : Job.Model
defaultModel =
    Job.init
        { jobId = someJobInfo
        , paging = Nothing
        }
        |> Tuple.first


init : { disabled : Bool, paused : Bool } -> () -> Application.Model
init { disabled, paused } _ =
    Common.init "/teams/team/pipelines/pipeline/jobs/job"
        |> Application.handleCallback
            (JobFetched <|
                Ok
                    (Data.job 1
                        |> Data.withName "job"
                        |> Data.withPipelineName "pipeline"
                        |> Data.withTeamName "team"
                        |> Data.withFinishedBuild (Just someBuild)
                        |> Data.withPaused paused
                        |> Data.withDisableManualTrigger disabled
                    )
            )
        |> Tuple.first


jobVars : List Concourse.JobVar
jobVars =
    [ { name = "branch"
      , type_ = Concourse.JobVarString
      , options = []
      , default = Just (JsonString "main")
      , description = Just "branch to build"
      , required = False
      }
    , { name = "count"
      , type_ = Concourse.JobVarNumber
      , options = []
      , default = Just (JsonNumber 1)
      , description = Nothing
      , required = False
      }
    , { name = "confirm_release"
      , type_ = Concourse.JobVarBoolean
      , options = []
      , default = Nothing
      , description = Nothing
      , required = True
      }
    , { name = "dry_run"
      , type_ = Concourse.JobVarBoolean
      , options = []
      , default = Just (JsonBoolean False)
      , description = Just "skip cloning"
      , required = False
      }
    , { name = "deploy_env"
      , type_ = Concourse.JobVarEnum
      , options = [ "dev", "prod" ]
      , default = Just (JsonString "dev")
      , description = Nothing
      , required = False
      }
    , { name = "environment"
      , type_ = Concourse.JobVarString
      , options = []
      , default = Nothing
      , description = Nothing
      , required = True
      }
    ]


initWithVars : () -> Application.Model
initWithVars _ =
    Common.init "/teams/team/pipelines/pipeline/jobs/job"
        |> Application.handleCallback
            (JobFetched <|
                Ok
                    (Data.job 1
                        |> Data.withName "job"
                        |> Data.withPipelineName "pipeline"
                        |> Data.withTeamName "team"
                        |> Data.withFinishedBuild (Just someBuild)
                        |> Data.withJobVars jobVars
                    )
            )
        |> Tuple.first


loadingIndicatorSelector : List Selector.Selector
loadingIndicatorSelector =
    [ style "animation"
        "container-rotate 1568ms linear infinite"
    , style "height" "14px"
    , style "width" "14px"
    , style "margin" "0 7px"
    ]


toggleJobID =
    Effects.toHtmlID ToggleJobButton
