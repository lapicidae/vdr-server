pipeline {
	environment {
		registry = "lapicidae/vdr-server"
		registryCredential = 'dockerhub'
		registryTag = 'latest'
		//gitURL = 'https://github.com/lapicidae/vdr-server.git'
		dockerImage = ''
	}
	agent any
	stages {
		stage('Clone') {
			steps{
				echo 'Cloning....'
				checkout scm
				//git gitURL
			}
		}
		stage('Build') {
			steps{
				echo 'Building....'
				script {
					dockerImage = docker.build registry + ":$BUILD_NUMBER"
				}
			}
		}
		stage('Publish') {
			steps{
				echo 'Publishing....'
				script {
					docker.withRegistry( '', registryCredential ) {
						dockerImage.push(registryTag)
					}
				}
			}
		}
		stage('Clean') {
			steps{
				echo 'Cleaning....'
				sh "docker rmi $registry:$BUILD_NUMBER || echo Failed to remove image $registry:$BUILD_NUMBER."
				sh "docker rmi $registry:$registryTag || echo Failed to remove image $registry:$BUILD_NUMBER."
			}
		}
	}
}
