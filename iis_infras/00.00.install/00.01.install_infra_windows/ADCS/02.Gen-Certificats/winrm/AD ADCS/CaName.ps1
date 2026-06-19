

(Get-ADObject -Filter "Name -like '*CA*'" -SearchBase "CN=Enrollment Services,CN=Public Key Services,CN=Services,$((Get-ADRootDSE).configurationNamingContext)").Name