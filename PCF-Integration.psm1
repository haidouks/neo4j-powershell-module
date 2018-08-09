function New-PCFLogin {
    [CmdletBinding()]
    param (
        [string]
        $UserName,
        [string]
        $Password,
        [string]
        $ApiUrl,
        [string]
        $Org
    )
    begin {
        Write-Verbose -Message "Log-in in progress:`nUserName:$UserName`nApiUrl:$ApiUrl`nOrg:$Org"
        $null = echo "" | cf login -u $UserName -p $Password -a $ApiUrl -o $Org --skip-ssl-validation
    }
    process {
        Write-Verbose -Message "Getting Oauth-Token"
        return $(cf oauth-token)
    }
}
function Get-PCFSpaces {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline,Mandatory)]
        [string]
        $Environment
    )
    begin {
        Write-Verbose -Message "Getting Spaces for env:$Environment"
        $cf_spaces = cf spaces
    }
    process {
        $spaceList = [System.Collections.ArrayList]::new()
        foreach ($space in $cf_spaces) {
            if( (-not [string]::IsNullOrEmpty($space)) -and $space.EndsWith("$Environment") ) {
                Write-Verbose -Message "Adding space $space to the list"
                $null = $spaceList.Add($space)
            }
        }
        Write-Verbose -Message "Returning space list"
        if($spaceList.Count -eq 0) {
            throw "No spaces found for suffix: $Environment. Please check suffix parameter in yml file."
        }
        return $($spaceList | ConvertTo-Json)
    }
}
function Get-PCFApps {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline,Mandatory)]
        $Space,
        [Parameter(Mandatory)]
        [string]
        $Org
    )
    begin {
        Write-Verbose -Message "Getting guid for $Space"
        $spaceGUID = cf space $Space --guid
    }
    process {
        Write-Verbose -Message "Getting applications`nSpace:$Space"
        $apps = cf curl "/v2/spaces/$spaceGUID/summary"
        return (($apps | ConvertFrom-Json).apps.name | ConvertTo-Json)
    }
}
function Get-PCFUserProvidedServices {
    [CmdletBinding()]
    param (
    # Parameter help description
    [Parameter(Mandatory,ValueFromPipeline)]
    [String]
    $Space
    )
    process {
        $spaceGUID = cf space $Space --guid
        $services = cf curl "/v2/spaces/$spaceGUID/summary"
        return (($services | ConvertFrom-Json).services.name | ConvertTo-Json)
    }
}
function Get-PCFEnvVars {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,ValueFromPipeline)]
        [string]
        $Application,
        [Parameter(Mandatory)]
        [string]
        $Space
    )
    begin {
        Write-Verbose -Message "Getting guid for $space"
        $spaceGUID = cf space $Space --guid
    }
    process {
        Write-Verbose -Message "Getting info for $Application"
        $applicationInfo = $(cf curl "/v2/spaces/$spaceGUID/apps?q=name:$Application&inline-relations-depth=1" | ConvertFrom-Json)
        return $( $applicationInfo.resources.entity.environment_json |convertto-json )
    }
}
function Set-PCFUserProvidedService {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [String]
        $Space,
        [Parameter(ValueFromPipeline,Mandatory)]
        $UserProvidedService
    )

    begin {
        Write-Verbose -Message "Getting guid for $Space"
        $spaceGUID = cf space $Space --guid
    }

    process {
        $serviceObject = @{
            "name"="$($UserProvidedService.name)"
            "credentials"= $UserProvidedService.credentials
            "space_guid"= "$spaceGUID"
        }

        $serviceInfo = cf curl "/v2/spaces/$spaceGUID/service_instances?return_user_provided_service_instances=true&q=name:$($UserProvidedService.name)&inline-relations-depth=1"
        if(($serviceInfo | ConvertFrom-Json).total_results -eq 0) {
            Write-Verbose -Message "Creating new user provided variable($($UserProvidedService.name)) for $Space"
            $json = "'$($($serviceObject | ConvertTo-Json -Compress).replace('"','\"'))'"
            Write-Verbose -Message "Posting json:`n$json"
            cf curl -X POST /v2/user_provided_service_instances -d $json
        }
        else {
            Write-Verbose -Message "Updating new user provided variable($($UserProvidedService.name)) for $Space"
            Write-Verbose -Message "Getting GUID"
            $serviceGUID = ($serviceInfo | ConvertFrom-Json).resources.metadata.guid
            $serviceObject.Remove("name")
            $json = "'$($($serviceObject | ConvertTo-Json -Compress).replace('"','\"'))'"
            Write-Verbose -Message "Posting json:`n$json"
            cf curl -X PUT /v2/user_provided_service_instances/$serviceGUID -d $json
        }
    }
    end {
    }
}
function Get-PCFUserProvidedService {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [String]
        $Space,
        [Parameter(ValueFromPipeline,Mandatory)]
        [String]
        $UserProvidedService
    )

    begin {
        Write-Verbose -Message "Getting guid for $Space"
        $spaceGUID = cf space $Space --guid
    }

    process {
        Write-Verbose -Message "Getting details for $UserProvidedService"
        $serviceInfo = $(cf curl "/v2/spaces/$spaceGUID/service_instances?q=name:$UserProvidedService&return_user_provided_service_instances=true" | ConvertFrom-Json)
        Write-Verbose -Message "Returning info"
        return $($serviceInfo.resources.entity.credentials | ConvertTo-Json)
    }
}

function Get-PCFBoundedApps {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [String]
        $Space,
        [Parameter(ValueFromPipeline,Mandatory)]
        [String]
        $UserProvidedService
    )

    begin {
        Write-Verbose -Message "Getting guid for $Space"
        $spaceGUID = cf space $Space --guid
        Write-Verbose -Message "$Space Guid:$spaceGuid"
    }

    process {
        $boundedApps = [System.Collections.ArrayList]::new()
        Write-Verbose -Message "Getting details for $UserProvidedService"
        $serviceInfoUrl = "/v2/spaces/$spaceGUID/service_instances?q=name:$UserProvidedService&return_user_provided_service_instances=true"
        Write-Verbose -Message "Service info url: $serviceInfoUrl"
        $serviceInfo = $(cf curl $serviceInfoUrl | ConvertFrom-Json)
        $serviceUrl = $serviceInfo.resources.entity.service_bindings_url
        Write-Verbose -Message "Received service url for $UserProvidedService :$serviceUrl"
        $serviceInfo = $(cf curl "$serviceUrl" | ConvertFrom-Json)
        $boundedAppGuids = $serviceInfo.resources.entity.app_guid
        Write-Verbose -Message "Recevied bounded app guids:`n$boundedAppGuids"
        foreach ($boundedAppGuid in $boundedAppGuids) {
            Write-Verbose -Message "Getting application name for $boundedAppGuid"
            $application = $(cf curl "/v2/apps/$boundedAppGuid" | ConvertFrom-Json)
            Write-Verbose -Message "Application name is $($application.entity.name)"
            $null = $boundedApps.Add($application.entity.name)
        }
        Write-Verbose -Message "Returning bounded applications"
        return $boundedApps
    }
}