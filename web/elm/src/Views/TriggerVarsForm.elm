module Views.TriggerVarsForm exposing (errorMessage, view)

import Colors
import Concourse
import Dict exposing (Dict)
import Html exposing (Html)
import Html.Attributes exposing (attribute, checked, for, id, selected, style, type_, value)
import Html.Events exposing (onCheck, onClick, onInput)
import Http
import Json.Decode
import Json.Encode
import Message.Effects exposing (toHtmlID)
import Message.Message exposing (DomID(..), Message(..))


view :
    { headerContent : List (Html Message)
    , vars : List Concourse.JobVar
    , values : Dict String String
    , error : Maybe String
    }
    -> Html Message
view { headerContent, vars, values, error } =
    Html.div
        (id "trigger-build-form" :: triggerBuildForm)
        (headerContent
            ++ (Html.div
                    triggerBuildFormWarning
                    [ Html.text "Trigger values are stored with build metadata. Do not enter secrets." ]
                    :: (vars
                            |> List.sortBy .name
                            |> List.map (viewVar values)
                       )
               )
            ++ viewError error
            ++ [ Html.div
                    triggerBuildFormFooter
                    [ Html.button
                        ([ id <| toHtmlID TriggerBuildFormSubmitButton
                         , onClick <| Click TriggerBuildFormSubmitButton
                         ]
                            ++ triggerBuildFormSubmitButton
                        )
                        [ Html.text "trigger" ]
                    , Html.button
                        ([ id <| toHtmlID TriggerBuildFormCancelButton
                         , onClick <| Click TriggerBuildFormCancelButton
                         ]
                            ++ triggerBuildFormCancelButton
                        )
                        [ Html.text "cancel" ]
                    ]
               ]
        )


viewError : Maybe String -> List (Html Message)
viewError error =
    case error of
        Nothing ->
            []

        Just message ->
            [ Html.div
                (id "trigger-build-form-error" :: triggerBuildFormError)
                [ Html.text ("failed to trigger: " ++ message) ]
            ]


{-| A human-readable message for a failed trigger request, preferring the
{"error": "..."} envelope the job endpoints return.
-}
errorMessage : Http.Error -> String
errorMessage error =
    case error of
        Http.BadStatus response ->
            case Json.Decode.decodeString (Json.Decode.field "error" Json.Decode.string) response.body of
                Ok message ->
                    message

                Err _ ->
                    if String.trim response.body /= "" then
                        String.trim response.body

                    else
                        "unexpected response (HTTP " ++ String.fromInt response.status.code ++ ")"

        Http.Timeout ->
            "the request timed out"

        Http.NetworkError ->
            "network error"

        _ ->
            "unexpected error"


viewVar : Dict String String -> Concourse.JobVar -> Html Message
viewVar values var =
    let
        requiredSuffix =
            if var.required then
                " (required)"

            else
                ""

        defaultText =
            case var.default of
                Nothing ->
                    ""

                Just (Concourse.JsonString s) ->
                    s

                Just (Concourse.JsonBoolean b) ->
                    boolToString b

                Just jsonValue ->
                    Json.Encode.encode 0 (Concourse.encodeJsonValue jsonValue)

        currentValue =
            Dict.get var.name values
                |> Maybe.withDefault defaultText

        currentBool =
            currentValue == "true"
    in
    Html.div
        triggerBuildFormVar
        [ Html.label
            (for (toHtmlID <| TriggerBuildFormVarField var.name)
                :: triggerBuildFormLabel
            )
            [ Html.text <|
                case var.description of
                    Just _ ->
                        var.name

                    Nothing ->
                        var.name ++ requiredSuffix
            ]
        , case var.description of
            Just description ->
                Html.div
                    triggerBuildFormDescription
                    [ Html.text <| description ++ requiredSuffix ]

            Nothing ->
                Html.text ""
        , viewControl var currentValue currentBool
        ]


viewControl : Concourse.JobVar -> String -> Bool -> Html Message
viewControl var currentValue currentBool =
    case var.type_ of
        Concourse.JobVarBoolean ->
            case var.default of
                Just (Concourse.JsonBoolean _) ->
                    Html.label
                        triggerBuildFormCheckboxRow
                        [ Html.input
                            ([ id <| toHtmlID <| TriggerBuildFormVarField var.name
                             , type_ "checkbox"
                             , checked currentBool
                             , onCheck
                                (\isChecked ->
                                    TriggerBuildVarChanged var.name <|
                                        if isChecked then
                                            "true"

                                        else
                                            "false"
                                )
                             ]
                                ++ triggerBuildFormCheckbox
                            )
                            []
                        , Html.span
                            triggerBuildFormCheckboxText
                            [ Html.text <|
                                if currentBool then
                                    "enabled"

                                else
                                    "disabled"
                            ]
                        ]

                _ ->
                    Html.select
                        ([ id <| toHtmlID <| TriggerBuildFormVarField var.name
                         , onInput <| TriggerBuildVarChanged var.name
                         ]
                            ++ triggerBuildFormInput
                        )
                        (viewBooleanOptions var currentValue)

        Concourse.JobVarEnum ->
            Html.select
                ([ id <| toHtmlID <| TriggerBuildFormVarField var.name
                 , onInput <| TriggerBuildVarChanged var.name
                 ]
                    ++ triggerBuildFormInput
                )
                (viewEnumOptions var currentValue)

        Concourse.JobVarNumber ->
            Html.input
                ([ id <| toHtmlID <| TriggerBuildFormVarField var.name
                 , type_ "number"
                 , attribute "step" "any"
                 , value currentValue
                 , onInput <| TriggerBuildVarChanged var.name
                 ]
                    ++ triggerBuildFormInput
                )
                []

        Concourse.JobVarString ->
            Html.input
                ([ id <| toHtmlID <| TriggerBuildFormVarField var.name
                 , type_ "text"
                 , value currentValue
                 , onInput <| TriggerBuildVarChanged var.name
                 ]
                    ++ triggerBuildFormInput
                )
                []


viewEnumOptions : Concourse.JobVar -> String -> List (Html Message)
viewEnumOptions var currentValue =
    let
        placeholderSelected =
            currentValue == ""

        placeholderLabel =
            if var.required then
                "-- select --"

            else
                "-- optional --"
    in
    (if currentValue == "" then
        [ Html.option
            [ value ""
            , selected placeholderSelected
            ]
            [ Html.text placeholderLabel ]
        ]

     else
        []
    )
        ++ List.map
            (\optionValue ->
                Html.option
                    [ value optionValue
                    , selected (optionValue == currentValue)
                    ]
                    [ Html.text optionValue ]
            )
            var.options


viewBooleanOptions : Concourse.JobVar -> String -> List (Html Message)
viewBooleanOptions var currentValue =
    let
        placeholderLabel =
            if var.required then
                "-- select --"

            else
                "-- optional --"
    in
    (if currentValue == "" then
        [ Html.option
            [ value ""
            , selected True
            ]
            [ Html.text placeholderLabel ]
        ]

     else
        []
    )
        ++ [ Html.option
                [ value "true"
                , selected (currentValue == "true")
                ]
                [ Html.text "true" ]
           , Html.option
                [ value "false"
                , selected (currentValue == "false")
                ]
                [ Html.text "false" ]
           ]


boolToString : Bool -> String
boolToString value =
    if value then
        "true"

    else
        "false"


triggerBuildForm : List (Html.Attribute msg)
triggerBuildForm =
    [ style "background-color" Colors.frame
    , style "padding" "20px 30px"
    , style "border-bottom" <| "1px solid " ++ Colors.border
    ]


triggerBuildFormVar : List (Html.Attribute msg)
triggerBuildFormVar =
    [ style "margin-bottom" "15px" ]


triggerBuildFormLabel : List (Html.Attribute msg)
triggerBuildFormLabel =
    [ style "display" "block"
    , style "font-weight" "700"
    , style "color" Colors.text
    , style "margin-bottom" "5px"
    ]


triggerBuildFormDescription : List (Html.Attribute msg)
triggerBuildFormDescription =
    [ style "color" Colors.asciiArt
    , style "font-size" "12px"
    , style "margin-bottom" "5px"
    ]


triggerBuildFormWarning : List (Html.Attribute msg)
triggerBuildFormWarning =
    [ style "color" Colors.paused
    , style "font-size" "12px"
    , style "margin-bottom" "15px"
    ]


triggerBuildFormInput : List (Html.Attribute msg)
triggerBuildFormInput =
    [ style "display" "block"
    , style "box-sizing" "border-box"
    , style "width" "100%"
    , style "max-width" "400px"
    , style "padding" "8px"
    , style "background-color" Colors.secondaryTopBar
    , style "border" <| "1px solid " ++ Colors.inputOutline
    , style "color" Colors.text
    , style "font-size" "12px"
    , style "outline" "none"
    ]


triggerBuildFormCheckboxRow : List (Html.Attribute msg)
triggerBuildFormCheckboxRow =
    [ style "display" "inline-flex"
    , style "align-items" "center"
    , style "gap" "10px"
    , style "color" Colors.text
    ]


triggerBuildFormCheckbox : List (Html.Attribute msg)
triggerBuildFormCheckbox =
    [ style "width" "16px"
    , style "height" "16px"
    , style "margin" "0"
    , style "accent-color" Colors.paginationHover
    ]


triggerBuildFormCheckboxText : List (Html.Attribute msg)
triggerBuildFormCheckboxText =
    [ style "font-size" "12px"
    ]


triggerBuildFormError : List (Html.Attribute msg)
triggerBuildFormError =
    [ style "color" Colors.failure
    , style "font-size" "13px"
    , style "margin-bottom" "12px"
    ]


triggerBuildFormFooter : List (Html.Attribute msg)
triggerBuildFormFooter =
    [ style "display" "flex"
    , style "align-items" "center"
    ]


triggerBuildFormButton : List (Html.Attribute msg)
triggerBuildFormButton =
    [ style "padding" "8px 16px"
    , style "outline" "none"
    , style "cursor" "pointer"
    , style "font-size" "12px"
    , style "margin-right" "10px"
    ]


triggerBuildFormSubmitButton : List (Html.Attribute msg)
triggerBuildFormSubmitButton =
    [ style "background-color" Colors.paginationHover
    , style "border" <| "1px solid " ++ Colors.inputOutline
    , style "color" Colors.text
    ]
        ++ triggerBuildFormButton


triggerBuildFormCancelButton : List (Html.Attribute msg)
triggerBuildFormCancelButton =
    [ style "background-color" "transparent"
    , style "border" <| "1px solid " ++ Colors.inputOutline
    , style "color" Colors.text
    ]
        ++ triggerBuildFormButton
