# ==============================================================================
# Updated:      2019-03-21
# Created by:   Justin Johns
# Filename:     AWSReporting.psm1
# Link:         https://github.com/johnsarie27/AWSReporting
# ==============================================================================

# CFTEMPLATEBUILDER FUNCTIONS
. $PSScriptRoot\ConvertTo-SecurityGroupObject.ps1
. $PSScriptRoot\ConvertTo-VpcObject.ps1
. $PSScriptRoot\ConvertTo-SubnetObject.ps1
. $PSScriptRoot\ConvertTo-RouteTableObject.ps1
. $PSScriptRoot\Export-SecurityGroup.ps1

# IAM FUNCTIONS
. $PSScriptRoot\Edit-AWSProfile.ps1
. $PSScriptRoot\Get-IAMReport.ps1
. $PSScriptRoot\Revoke-StaleAccessKey.ps1
. $PSScriptRoot\Disable-InactiveUserKey.ps1
. $PSScriptRoot\Disable-InactiveUserProfile.ps1

# INVENTORY AND BUDGETARY FUNCTIONS
. $PSScriptRoot\Find-InsecureS3BucketPolicy.ps1
. $PSScriptRoot\Find-PublicS3Objects.ps1
. $PSScriptRoot\Get-SecurityGroupInfo.ps1
. $PSScriptRoot\Get-NetworkInfo.ps1
. $PSScriptRoot\Get-ELB.ps1
. $PSScriptRoot\Get-EC2.ps1
. $PSScriptRoot\Get-AvailableEBS.ps1
. $PSScriptRoot\New-QuarterlyReport.ps1
. $PSScriptRoot\Get-InstanceList.ps1
. $PSScriptRoot\Get-AWSPriceData.ps1
. $PSScriptRoot\Remove-LapsedAMI.ps1

# DEPRICATED
#. $PSScriptRoot\Get-CostInfo.ps1

# THIS IMPORT CAUSES PROBLEMS WITH USING Get-Command -Module AWSReporting
# OR USING PLATYPS TO GENERATE AND UPDATE MODULE HLEP
#if ( $PSVersionTable.PSVersion.Major -eq 6 ) { Import-Module -Name AWSPowerShell.NetCore }
#else { Import-Module -Name AWSPowershell }

# FUNCTIONS
function New-ResourceObject {
    [CmdletBinding(DefaultParameterSetName = 'EIP')]
    Param(
        [Parameter(Mandatory, ParameterSetName = 'EIP', HelpMessage = 'Elastic IP')]
        [switch] $EIP,

        [Parameter(Mandatory, ParameterSetName = 'NGW', HelpMessage = 'NAT Gateway')]
        [switch] $NGW,

        [Parameter(Mandatory, ParameterSetName = 'IGW', HelpMessage = 'Internet Gateway')]
        [switch] $IGW,

        [Parameter(Mandatory, ParameterSetName = 'VGA', HelpMessage = 'VPC Gateway Attachment')]
        [switch] $VGA,

        [Parameter(HelpMessage = 'Value for name tag')]
        [ValidateScript({ $_ -match '[A-Z0-9-_]' })]
        [string] $NameTag,

        [Parameter(Mandatory, ParameterSetName = 'NGW', HelpMessage = 'Elast IP name')]
        [ValidateScript({ $_ -match '[A-Z0-9-_]' })]
        [string] $EipName,

        [Parameter(Mandatory, ParameterSetName = 'NGW', HelpMessage = 'Subnet name')]
        [ValidateScript({ $_ -match '[A-Z0-9-_]' })]
        [string] $SubnetName
    )

    $ParamSwitch = @('EIP', 'NGW', 'IGW', 'VGA')
    switch ( $PSBoundParameters.Keys | Where-Object { $_ -in $ParamSwitch } ) {
        'EIP' {
            $ResourceType = 'EIP'
            $Hash = @{ Domain = "vpc" }
        }
        'NGW' {
            $ResourceType = 'NatGateway'
            $Hash = @{
                AllocationId = [PSCustomObject] @{ "Fn::GetAtt" = @($EipName, "AllocationId") }
                SubnetId     = [PSCustomObject] @{ Ref = "$SubnetName" } 
            }    
        }
        'IGW' { $ResourceType = 'InternetGateway' }
        'VGA' {
            $ResourceType = 'VPCGatewayAttachment'
            $Hash = @{
                VpcId = [PSCustomObject] @{ Ref = "rVPC" }
                InternetGatewayId = [PSCustomObject] @{ Ref = "rInternetGateway" }
            }
        }
    }

    if ( $Hash -and $NameTag ) { $Hash.Tags = [PSCustomObject] @{ Key = "Name" ; Value = $NameTag } }
    if ( -not $Hash -and $NameTag ) { $Hash = @{ Tags = [PSCustomObject] @{ Key = "Name" ; Value = $NameTag } } }

    # ADD DATA VALUES AND OBJECTS
    $Object = [PSCustomObject] @{ Type = "AWS::EC2::$ResourceType" }
    if ( $Hash ) { $Properties = [PSCustomObject] $Hash }
    $Object | Add-Member -MemberType NoteProperty -Name "Properties" -Value $Properties

    # RETURN MASTER OBJECT
    $Object
}

# CLASS
class EC2Instance {
    [String] $Id
    [String] $Name
    [String] $Type
    [String] $Reserved
    [String] $AZ
    [String] $PrivateIp = $null
    [String] $PublicIp = $null
    [String[]] $AllPrivateIps
    [String] $State
    [String] $DR_Region
    [DateTime] $LastStart
    [Int] $DaysStopped
    [Int] $DaysRunning
    [String] $Stopper
    [DateTime] $LastStopped
    [double] $OnDemandPrice
    [double] $ReservedPrice
    [string] $Savings
    [string] $ProfileName
    [string] $Region
    [bool] $IllegalName = $false
    [string[]] $NameTags
    [string] $VpcId
    [string] $VpcName
    [string] $SubnetId
    [string] $SubnetName
    [string[]] $SecurityGroups

    <# 
    # DEFAULT CONSTRUCTOR
    EC2Instance() {}

    # CUSTOM CONSTRUCTOR
    EC2Instance([Amazon.EC2.Model.Instance] $EC2) {
        
        $this.DR_Region = ( $EC2.Tags | Where-Object Key -eq DR_Region ).Value
        $this.Id = $EC2.InstanceId
        $this.Name = ( $EC2.Tags | Where-Object Key -ceq Name ).Value
        $this.Type = $EC2.InstanceType.Value
        $this.Reserved = ( $EC2.Tags | Where-Object Key -eq RI_Candidate ).Value
        $this.AZ = $EC2.Placement.AvailabilityZone
        $this.PrivateIP = $EC2.PrivateIpAddress
        $this.PublicIP = $EC2.PublicIpAddress
        $this.AllPrivateIps = $EC2.NetworkInterfaces.PrivateIpAddresses.PrivateIpAddress
        $this.State = $EC2.State.Name.Value
        if ( $EC2.LaunchTime ) { $this.LastStart = $EC2.LaunchTime }
        $this.ProfileName = ""
        $this.Region = ""
        $this.GetDaysRunning()
        $IllegalChars = '(!|"|#|\$|%|&|''|\*|\+|,|:|;|\<|=|\>|\?|@|\[|\\|\]|\^|`|\{|\||\}|~)'
        if ( $this.Name -match $IllegalChars ) { $this.IllegalName = $true }
        $this.NameTags = $EC2.Tags | Where-Object Key -EQ name | Select-Object -EXP Value
        $this.VpcId = $EC2.VpcId
        $this.SubnetId = $EC2.SubnetId
        $this.SecurityGroups = $EC2.SecurityGroups.GroupName
        
    }
    #>

    [string] ToString() { return ( "{0}" -f $this.Id ) }

    [void] GetNetInfo($ProfileName, $Region) {
        $this.VpcName = ((Get-EC2Vpc -VpcId $this.VpcId -Region $Region -ProfileName $ProfileName).Tags | Where-Object Key -EQ Name).Value
        $this.SubnetName = ((Get-EC2Subnet -SubnetId $this.SubnetId -Region $Region -ProfileName $ProfileName).Tags | Where-Object Key -eq Name).Value
    }

    [void] GetDaysRunning() {
        if ( $this.State -eq 'running' ) {
            $this.DaysRunning = (New-TimeSpan -Start $this.LastStart -End (Get-Date)).Days
        } else { $this.DaysRunning = 0 }
    }

    [void] GetStopInfo() {
        if ( $this.State -eq 'stopped' ) {
            $event = Find-CTEvent -Region $this.Region -ProfileName $this.ProfileName -LookupAttribute @{
                AttributeKey = "ResourceName"; AttributeValue = $this.Id
                } | Where-Object EventName -eq 'StopInstances' | Select-Object -First 1
            if ( $event ) {
                $this.LastStopped = $event.EventTime
                $this.Stopper = $event.Username
                $this.DaysStopped = (New-TimeSpan -Start $event.EventTime -End (Get-Date)).Days
            } else {
                $this.DaysStopped = 99 ; $this.Stopper = 'unknown'
            }
        } else { $this.Stopper = '(running)' }
    }

    [void] GetCostInfo() {
        $RegionTable = @{
            'us-east-1' = 'US East (N. Virginia)'
            'us-east-2' = 'US East (Ohio)'
            'us-west-1' = 'US West (N. California)'
            'us-west-2' = 'US West (Oregon)'
        }
        $DataFile = "$env:ProgramData\AWS\AmazonEC2_PriceData.csv"
        if ( -not ( Test-Path $DataFile ) ) { Get-AWSPriceData }

        $PriceInfo = Import-Csv -Path $DataFile | Where-Object Location -eq $RegionTable[$this.Region]
        foreach ( $price in $PriceInfo ) {
            if ( ( $this.Type -eq $price.'Instance Type' ) -and ( $price.TermType -eq 'OnDemand' ) ) {
                [double]$ODP = [math]::Round($price.PricePerUnit,3)
                $this.OnDemandPrice = [math]::Round( $ODP * 24 * 365 )
            }
            if ( ( $this.Type -eq $price.'Instance Type' ) -and ( $price.TermType -eq 'Reserved' ) ) {
                $this.ReservedPrice = $price.PricePerUnit
            }
        }
        $this.Savings = ( 1 - ( $this.ReservedPrice / $this.OnDemandPrice ) ).ToString("P")
    }

}

# VARIABLES
$RegionTable = @{
    'us-east-1' = 'US East (N. Virginia)'
    'us-east-2' = 'US East (Ohio)'
    'us-west-1' = 'US West (N. California)'
    'us-west-2' = 'US West (Oregon)'
}

$IllegalChars = '(!|"|#|\$|%|&|''|\*|\+|,|:|;|\<|=|\>|\?|@|\[|\\|\]|\^|`|\{|\||\}|~)'

$AlphabetList = 0..25 | ForEach-Object { [char](65 + $_) }

[int] $i = 0 ; $VolumeLookupTable = @{}
foreach ( $letter in $AlphabetList ) {
    $key = 'T' + $i.ToString("00") ; [string] $value = ('xvd' + $letter).ToLower()
    $VolumeLookupTable.Add( $key, $value ) ; $i++
}
$VolumeLookupTable.T00 = '/dev/sda1/'

# EXPORT MEMBERS
# EXPORTING IS SPECIFIED IN THE MODULE MANIFEST AND UNNECESSARY HERE
#Export-ModuleMember -Function *
#Export-ModuleMember -Variable *
